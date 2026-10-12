package com.iflytek.skillhub.auth.trustedheader;

import com.iflytek.skillhub.auth.bootstrap.PassiveSessionAuthenticator;
import com.iflytek.skillhub.auth.oauth.OAuthClaims;
import com.iflytek.skillhub.auth.oauth.OAuthLoginFlowService;
import com.iflytek.skillhub.auth.rbac.PlatformPrincipal;
import jakarta.servlet.http.HttpServletRequest;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.atomic.AtomicBoolean;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.security.core.AuthenticationException;
import org.springframework.stereotype.Component;

/**
 * Passive session authenticator for deployments where a forward-auth gateway
 * has already authenticated the browser and injects the identity as request
 * headers.
 *
 * <p>This is the Open WebUI style "trusted header" model adapted to the
 * platform's standardized session bootstrap: the login page performs one
 * explicit {@code POST /api/v1/auth/session/bootstrap} call, this component maps
 * the headers into normalized {@link OAuthClaims}, and the shared OAuth login
 * flow performs access-policy evaluation, just-in-time account creation, and
 * role assignment before the caller persists a first-party Spring Security
 * session.
 *
 * <p>Trust is anchored outside the application: the gateway must be the only
 * route to the service and must overwrite the configured headers. Configuring
 * {@code skillhub.auth.trusted-header.shared-secret} adds an in-application
 * proof on top of that isolation, because {@code forward-headers-strategy=framework}
 * makes the peer address unreliable for a trusted-proxy check.
 */
@Component
@ConditionalOnProperty(name = "skillhub.auth.trusted-header.enabled", havingValue = "true")
public class TrustedHeaderPassiveSessionAuthenticator implements PassiveSessionAuthenticator {

    private static final Logger log = LoggerFactory.getLogger(TrustedHeaderPassiveSessionAuthenticator.class);

    private final TrustedHeaderAuthProperties properties;
    private final OAuthLoginFlowService oauthLoginFlowService;
    private final AtomicBoolean missingSecretWarningLogged = new AtomicBoolean(false);

    public TrustedHeaderPassiveSessionAuthenticator(TrustedHeaderAuthProperties properties,
                                                    OAuthLoginFlowService oauthLoginFlowService) {
        this.properties = properties;
        this.oauthLoginFlowService = oauthLoginFlowService;
    }

    @Override
    public String providerCode() {
        return properties.getProviderCode();
    }

    @Override
    public String displayName() {
        return properties.getDisplayName();
    }

    @Override
    public Optional<PlatformPrincipal> authenticate(HttpServletRequest request) {
        if (!isTrustedGatewayRequest(request)) {
            return Optional.empty();
        }

        String userName = trimToNull(request.getHeader(properties.getUserHeader()));
        if (userName == null) {
            return Optional.empty();
        }

        String email = trimToNull(request.getHeader(properties.getEmailHeader()));
        OAuthClaims claims = new OAuthClaims(
                properties.getProviderCode(),
                userName,
                email,
                email != null,
                userName,
                Map.of()
        );

        try {
            PlatformPrincipal principal = oauthLoginFlowService.authenticate(claims);
            log.info("Trusted header authentication succeeded: provider={}, rolesCount={}",
                    claims.provider(), principal.platformRoles().size());
            return Optional.of(principal);
        } catch (AuthenticationException ex) {
            // Pending, disabled, merged, or policy-denied accounts must look like a failed
            // upstream session; the caller turns this into a plain 401 without leaking state.
            log.info("Trusted header authentication rejected: provider={}, reason={}",
                    claims.provider(), ex.getClass().getSimpleName());
            return Optional.empty();
        }
    }

    private boolean isTrustedGatewayRequest(HttpServletRequest request) {
        String expectedSecret = trimToNull(properties.getSharedSecret());
        if (expectedSecret == null) {
            if (missingSecretWarningLogged.compareAndSet(false, true)) {
                log.warn("Trusted header authentication is enabled without "
                        + "'skillhub.auth.trusted-header.shared-secret'; header origin is not verified "
                        + "by the application and must be enforced by network isolation");
            }
            return true;
        }
        String presentedSecret = trimToNull(request.getHeader(properties.getSharedSecretHeader()));
        if (presentedSecret == null) {
            log.warn("Trusted header request rejected: gateway shared secret header is missing");
            return false;
        }
        if (!MessageDigest.isEqual(
                presentedSecret.getBytes(StandardCharsets.UTF_8),
                expectedSecret.getBytes(StandardCharsets.UTF_8))) {
            log.warn("Trusted header request rejected: gateway shared secret mismatch");
            return false;
        }
        return true;
    }

    private String trimToNull(String value) {
        if (value == null) {
            return null;
        }
        String trimmed = value.trim();
        return trimmed.isEmpty() ? null : trimmed;
    }
}
