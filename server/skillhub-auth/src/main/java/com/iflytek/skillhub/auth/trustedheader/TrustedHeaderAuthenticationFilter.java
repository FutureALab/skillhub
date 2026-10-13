package com.iflytek.skillhub.auth.trustedheader;

import com.iflytek.skillhub.auth.rbac.PlatformPrincipal;
import com.iflytek.skillhub.auth.session.PlatformSessionService;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.util.Optional;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

/**
 * Per-request trusted-header authentication: every request that carries the
 * configured gateway headers is signed in automatically, with no login page and
 * no explicit bootstrap call.
 *
 * <p>This is the Open WebUI style transparent mode. The first authenticated
 * request establishes a normal SkillHub session so the rest of the platform
 * (request context projection, CSRF, audit, logout) keeps working unchanged;
 * later requests reuse that session, and API tokens or an existing session always
 * take precedence over the headers.
 *
 * <p>Anchoring trust outside the application is mandatory: the gateway must be the
 * only route to the service and must overwrite the headers. Configure
 * {@code skillhub.auth.trusted-header.shared-secret} to additionally require a
 * gateway shared secret. Because a session outlives the request, a user cannot
 * effectively log out while the gateway keeps asserting their identity.
 */
@Component
@ConditionalOnProperty(
        name = {
            "skillhub.auth.trusted-header.enabled",
            "skillhub.auth.trusted-header.per-request-authentication"
        },
        havingValue = "true")
public class TrustedHeaderAuthenticationFilter extends OncePerRequestFilter {

    private static final Logger log = LoggerFactory.getLogger(TrustedHeaderAuthenticationFilter.class);

    private final TrustedHeaderIdentityResolver resolver;
    private final PlatformSessionService platformSessionService;

    public TrustedHeaderAuthenticationFilter(TrustedHeaderIdentityResolver resolver,
                                             PlatformSessionService platformSessionService) {
        this.resolver = resolver;
        this.platformSessionService = platformSessionService;
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response,
                                    FilterChain filterChain) throws ServletException, IOException {
        if (SecurityContextHolder.getContext().getAuthentication() == null) {
            Optional<PlatformPrincipal> principal = resolver.resolve(request);
            if (principal.isPresent()) {
                // Rotate only a freshly created session: rotating on every request would break
                // concurrent requests from the same browser.
                boolean createdSession = request.getSession(false) == null;
                platformSessionService.establishSession(principal.get(), request, createdSession);
                log.debug("Trusted header request authenticated: provider={}, sessionRotated={}",
                        principal.get().oauthProvider(), createdSession);
            }
        }
        filterChain.doFilter(request, response);
    }
}
