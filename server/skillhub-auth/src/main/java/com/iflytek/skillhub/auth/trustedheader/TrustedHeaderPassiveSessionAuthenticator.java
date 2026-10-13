package com.iflytek.skillhub.auth.trustedheader;

import com.iflytek.skillhub.auth.bootstrap.PassiveSessionAuthenticator;
import com.iflytek.skillhub.auth.rbac.PlatformPrincipal;
import jakarta.servlet.http.HttpServletRequest;
import java.util.Optional;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Component;

/**
 * Pull-model entry point for trusted gateway headers.
 *
 * <p>The login page performs one explicit {@code POST /api/v1/auth/session/bootstrap}
 * call and this component maps the headers into a platform principal. Deployments
 * that want every request to authenticate itself from the headers, without any
 * login-page round trip, should enable
 * {@code skillhub.auth.trusted-header.per-request-authentication} instead, which
 * registers {@link TrustedHeaderAuthenticationFilter}.
 */
@Component
@ConditionalOnProperty(name = "skillhub.auth.trusted-header.enabled", havingValue = "true")
public class TrustedHeaderPassiveSessionAuthenticator implements PassiveSessionAuthenticator {

    private final TrustedHeaderAuthProperties properties;
    private final TrustedHeaderIdentityResolver resolver;

    public TrustedHeaderPassiveSessionAuthenticator(TrustedHeaderAuthProperties properties,
                                                    TrustedHeaderIdentityResolver resolver) {
        this.properties = properties;
        this.resolver = resolver;
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
        return resolver.resolve(request);
    }
}
