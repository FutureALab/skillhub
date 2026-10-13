package com.iflytek.skillhub.auth.trustedheader;

import com.iflytek.skillhub.auth.oauth.AccountPendingException;
import com.iflytek.skillhub.auth.oauth.OAuthClaims;
import com.iflytek.skillhub.auth.oauth.OAuthLoginFlowService;
import com.iflytek.skillhub.auth.rbac.PlatformPrincipal;
import java.util.Optional;
import java.util.Set;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.mock.web.MockHttpServletRequest;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.BDDMockito.given;
import static org.mockito.BDDMockito.then;
import static org.mockito.Mockito.never;

@ExtendWith(MockitoExtension.class)
class TrustedHeaderIdentityResolverTest {

    private static final String USER_HEADER = "X-Auth-Request-User";
    private static final String EMAIL_HEADER = "X-Forwarded-Email";
    private static final String SECRET_HEADER = "X-Skillhub-Proxy-Secret";

    @Mock
    private OAuthLoginFlowService oauthLoginFlowService;

    private TrustedHeaderAuthProperties properties;
    private TrustedHeaderIdentityResolver resolver;

    @BeforeEach
    void setUp() {
        properties = new TrustedHeaderAuthProperties();
        resolver = new TrustedHeaderIdentityResolver(properties, oauthLoginFlowService);
    }

    @Test
    void mapsTrustedHeadersIntoVerifiedClaims() {
        PlatformPrincipal expected = principal("alice");
        given(oauthLoginFlowService.authenticate(any())).willReturn(expected);

        Optional<PlatformPrincipal> result = resolver.resolve(
                request(USER_HEADER, "alice", EMAIL_HEADER, "alice@example.com"));

        assertThat(result).contains(expected);
        ArgumentCaptor<OAuthClaims> claims = ArgumentCaptor.forClass(OAuthClaims.class);
        then(oauthLoginFlowService).should().authenticate(claims.capture());
        assertThat(claims.getValue().provider()).isEqualTo("forward-auth");
        assertThat(claims.getValue().subject()).isEqualTo("alice");
        assertThat(claims.getValue().providerLogin()).isEqualTo("alice");
        assertThat(claims.getValue().email()).isEqualTo("alice@example.com");
        assertThat(claims.getValue().emailVerified()).isTrue();
    }

    @Test
    void keepsEmailUnverifiedWhenEmailHeaderIsAbsent() {
        given(oauthLoginFlowService.authenticate(any())).willReturn(principal("alice"));

        resolver.resolve(request(USER_HEADER, "alice"));

        ArgumentCaptor<OAuthClaims> claims = ArgumentCaptor.forClass(OAuthClaims.class);
        then(oauthLoginFlowService).should().authenticate(claims.capture());
        assertThat(claims.getValue().email()).isNull();
        assertThat(claims.getValue().emailVerified()).isFalse();
    }

    @Test
    void returnsEmptyWhenUserHeaderIsMissing() {
        Optional<PlatformPrincipal> result = resolver.resolve(request(EMAIL_HEADER, "alice@example.com"));

        assertThat(result).isEmpty();
        then(oauthLoginFlowService).should(never()).authenticate(any());
    }

    @Test
    void returnsEmptyWhenUserHeaderIsBlank() {
        Optional<PlatformPrincipal> result = resolver.resolve(request(USER_HEADER, "   "));

        assertThat(result).isEmpty();
        then(oauthLoginFlowService).should(never()).authenticate(any());
    }

    @Test
    void returnsEmptyWhenUpstreamIdentityIsRejected() {
        given(oauthLoginFlowService.authenticate(any())).willThrow(new AccountPendingException());

        Optional<PlatformPrincipal> result = resolver.resolve(request(USER_HEADER, "pending-user"));

        assertThat(result).isEmpty();
    }

    @Test
    void rejectsRequestWhenSharedSecretIsMissing() {
        properties.setSharedSecret("gateway-secret");

        Optional<PlatformPrincipal> result = resolver.resolve(request(USER_HEADER, "alice"));

        assertThat(result).isEmpty();
        then(oauthLoginFlowService).should(never()).authenticate(any());
    }

    @Test
    void rejectsRequestWhenSharedSecretDoesNotMatch() {
        properties.setSharedSecret("gateway-secret");

        Optional<PlatformPrincipal> result = resolver.resolve(
                request(USER_HEADER, "alice", SECRET_HEADER, "wrong-secret"));

        assertThat(result).isEmpty();
        then(oauthLoginFlowService).should(never()).authenticate(any());
    }

    @Test
    void acceptsRequestWhenSharedSecretMatches() {
        properties.setSharedSecret("gateway-secret");
        given(oauthLoginFlowService.authenticate(any())).willReturn(principal("alice"));

        Optional<PlatformPrincipal> result = resolver.resolve(
                request(USER_HEADER, "alice", SECRET_HEADER, "gateway-secret"));

        assertThat(result).isPresent();
    }

    @Test
    void honoursCustomHeaderNames() {
        properties.setUserHeader("X-Forwarded-User");
        properties.setEmailHeader("X-Forwarded-Mail");
        given(oauthLoginFlowService.authenticate(any())).willReturn(principal("bob"));

        Optional<PlatformPrincipal> result = resolver.resolve(
                request("X-Forwarded-User", "bob", "X-Forwarded-Mail", "bob@example.com"));

        assertThat(result).isPresent();
        assertThat(resolver.resolve(request(USER_HEADER, "bob"))).isEmpty();
    }

    private MockHttpServletRequest request(String... headerPairs) {
        MockHttpServletRequest request = new MockHttpServletRequest();
        for (int i = 0; i + 1 < headerPairs.length; i += 2) {
            request.addHeader(headerPairs[i], headerPairs[i + 1]);
        }
        return request;
    }

    private PlatformPrincipal principal(String userId) {
        return new PlatformPrincipal(userId, userId, userId + "@example.com", null, "forward-auth", Set.of("USER"));
    }
}
