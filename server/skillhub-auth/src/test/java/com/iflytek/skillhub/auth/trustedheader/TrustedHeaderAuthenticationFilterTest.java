package com.iflytek.skillhub.auth.trustedheader;

import com.iflytek.skillhub.auth.rbac.PlatformPrincipal;
import com.iflytek.skillhub.auth.session.PlatformSessionService;
import jakarta.servlet.FilterChain;
import java.util.Optional;
import java.util.Set;
import java.util.concurrent.atomic.AtomicBoolean;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyBoolean;
import static org.mockito.BDDMockito.given;
import static org.mockito.BDDMockito.then;
import static org.mockito.Mockito.never;

@ExtendWith(MockitoExtension.class)
class TrustedHeaderAuthenticationFilterTest {

    @Mock
    private TrustedHeaderIdentityResolver resolver;

    @Mock
    private PlatformSessionService platformSessionService;

    private TrustedHeaderAuthenticationFilter filter;

    @BeforeEach
    void setUp() {
        filter = new TrustedHeaderAuthenticationFilter(resolver, platformSessionService);
        SecurityContextHolder.clearContext();
    }

    @AfterEach
    void clearSecurityContext() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void authenticatesRequestFromHeadersAndRotatesFreshSession() throws Exception {
        PlatformPrincipal principal = principal();
        given(resolver.resolve(any())).willReturn(Optional.of(principal));
        MockHttpServletRequest request = new MockHttpServletRequest();

        assertThat(chainCalled(request)).isTrue();

        then(platformSessionService).should().establishSession(principal, request, true);
    }

    @Test
    void reusesExistingSessionWithoutRotatingIt() throws Exception {
        PlatformPrincipal principal = principal();
        given(resolver.resolve(any())).willReturn(Optional.of(principal));
        MockHttpServletRequest request = new MockHttpServletRequest();
        request.getSession(true);

        chainCalled(request);

        then(platformSessionService).should().establishSession(principal, request, false);
    }

    @Test
    void skipsHeaderResolutionWhenRequestIsAlreadyAuthenticated() throws Exception {
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken("existing-principal", null));
        MockHttpServletRequest request = new MockHttpServletRequest();

        assertThat(chainCalled(request)).isTrue();

        then(resolver).should(never()).resolve(any());
        then(platformSessionService).should(never()).establishSession(any(), any(), anyBoolean());
    }

    @Test
    void continuesAnonymousWhenHeadersCarryNoIdentity() throws Exception {
        given(resolver.resolve(any())).willReturn(Optional.empty());
        MockHttpServletRequest request = new MockHttpServletRequest();

        assertThat(chainCalled(request)).isTrue();

        then(platformSessionService).should(never()).establishSession(any(), any(), anyBoolean());
    }

    private boolean chainCalled(MockHttpServletRequest request) throws Exception {
        AtomicBoolean called = new AtomicBoolean(false);
        FilterChain chain = (servletRequest, servletResponse) -> called.set(true);
        filter.doFilter(request, new MockHttpServletResponse(), chain);
        return called.get();
    }

    private PlatformPrincipal principal() {
        return new PlatformPrincipal("alice", "alice", "alice@example.com", null, "forward-auth", Set.of("USER"));
    }
}
