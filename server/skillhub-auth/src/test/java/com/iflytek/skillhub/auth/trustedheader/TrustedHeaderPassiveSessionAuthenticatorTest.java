package com.iflytek.skillhub.auth.trustedheader;

import com.iflytek.skillhub.auth.rbac.PlatformPrincipal;
import java.util.Optional;
import java.util.Set;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.mock.web.MockHttpServletRequest;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.BDDMockito.given;
import static org.mockito.BDDMockito.then;

@ExtendWith(MockitoExtension.class)
class TrustedHeaderPassiveSessionAuthenticatorTest {

    @Mock
    private TrustedHeaderIdentityResolver resolver;

    private TrustedHeaderAuthProperties properties;
    private TrustedHeaderPassiveSessionAuthenticator authenticator;

    @BeforeEach
    void setUp() {
        properties = new TrustedHeaderAuthProperties();
        authenticator = new TrustedHeaderPassiveSessionAuthenticator(properties, resolver);
    }

    @Test
    void exposesConfiguredProviderCodeAndDisplayName() {
        properties.setProviderCode("corp-gateway");
        properties.setDisplayName("Corp SSO");

        assertThat(authenticator.providerCode()).isEqualTo("corp-gateway");
        assertThat(authenticator.displayName()).isEqualTo("Corp SSO");
    }

    @Test
    void delegatesHeaderResolutionToTheSharedResolver() {
        PlatformPrincipal expected = new PlatformPrincipal(
                "alice", "alice", "alice@example.com", null, "forward-auth", Set.of("USER"));
        given(resolver.resolve(any())).willReturn(Optional.of(expected));

        Optional<PlatformPrincipal> result = authenticator.authenticate(new MockHttpServletRequest());

        assertThat(result).contains(expected);
        then(resolver).should().resolve(any());
    }
}
