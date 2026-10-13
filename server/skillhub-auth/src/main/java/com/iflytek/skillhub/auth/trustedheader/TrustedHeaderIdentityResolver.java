package com.iflytek.skillhub.auth.trustedheader;

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
import org.springframework.security.core.AuthenticationException;
import org.springframework.stereotype.Component;

/**
 * Turns trusted gateway headers into a platform principal.
 *
 * <p>Shared by every trusted-header entry point so header mapping, gateway
 * proof, and claim normalization cannot drift between them. The principal is
 * produced by the platform OAuth login flow, which applies the external access
 * policy, provisions a platform account on first sight, and grants the default
 * roles.
 *
 * <p>Trust is anchored outside the application: the gateway must be the only
 * route to the service and must overwrite the configured headers. Configuring
 * {@code skillhub.auth.trusted-header.shared-secret} adds an in-application
 * proof on top of that isolation, because {@code forward-headers-strategy=framework}
 * makes the peer address unreliable for a trusted-proxy check.
 */
@Component
public class TrustedHeaderIdentityResolver {

    private static final Logger log = LoggerFactory.getLogger(TrustedHeaderIdentityResolver.class);

    private final TrustedHeaderAuthProperties properties;
    private final OAuthLoginFlowService oauthLoginFlowService;
    private final AtomicBoolean missingSecretWarningLogged = new AtomicBoolean(false);

    public TrustedHeaderIdentityResolver(TrustedHeaderAuthProperties properties,
                                         OAuthLoginFlowService oauthLoginFlowService) {
        this.properties = properties;
        this.oauthLoginFlowService = oauthLoginFlowService;
    }

    /**
     * Resolves the identity asserted by the configured headers, or empty when the
     * request carries no trustworthy identity.
     */
    public Optional<PlatformPrincipal> resolve(HttpServletRequest request) {
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
            // upstream session; callers turn this into a plain 401 without leaking state.
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
