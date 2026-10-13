package com.iflytek.skillhub.controller;

import com.iflytek.skillhub.auth.local.LocalCredentialRepository;
import com.iflytek.skillhub.auth.oauth.OAuthClaims;
import com.iflytek.skillhub.auth.oauth.OAuthLoginFlowService;
import com.iflytek.skillhub.auth.rbac.PlatformPrincipal;
import com.iflytek.skillhub.auth.repository.UserRoleBindingRepository;
import com.iflytek.skillhub.auth.settings.LocalAuthSettings;
import com.iflytek.skillhub.auth.settings.LocalAuthSettingsService;
import com.iflytek.skillhub.domain.namespace.NamespaceMemberRepository;
import com.iflytek.skillhub.domain.user.UserAccount;
import com.iflytek.skillhub.domain.user.UserAccountRepository;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.web.servlet.MockMvc;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.BDDMockito.given;
import static org.mockito.BDDMockito.then;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Verifies transparent per-request trusted-header authentication: a request that carries the
 * gateway headers is signed in without any session, any CSRF dance, or any login-page interaction.
 */
@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("test")
@TestPropertySource(properties = {
    "skillhub.auth.trusted-header.enabled=true",
    "skillhub.auth.trusted-header.per-request-authentication=true",
    "skillhub.auth.trusted-header.display-name=Corp Gateway"
})
class TrustedHeaderFilterAuthenticationTest {

    @Autowired
    private MockMvc mockMvc;

    @MockBean
    private OAuthLoginFlowService oauthLoginFlowService;

    @MockBean
    private NamespaceMemberRepository namespaceMemberRepository;

    @MockBean
    private UserAccountRepository userAccountRepository;

    @MockBean
    private UserRoleBindingRepository userRoleBindingRepository;

    @MockBean
    private LocalCredentialRepository localCredentialRepository;

    @MockBean
    private LocalAuthSettingsService localAuthSettingsService;

    @BeforeEach
    void setUp() {
        given(localAuthSettingsService.current()).willReturn(new LocalAuthSettings(1L, true, true, 0L, null));
        given(oauthLoginFlowService.authenticate(any())).willReturn(new PlatformPrincipal(
            "alice", "alice", "alice@example.com", null, "forward-auth", Set.of("USER")));
        given(userAccountRepository.findById("alice"))
            .willReturn(Optional.of(new UserAccount("alice", "alice", "alice@example.com", null)));
        given(userRoleBindingRepository.findByUserId("alice")).willReturn(List.of());
        given(namespaceMemberRepository.findByUserId("alice")).willReturn(List.of());
        given(localCredentialRepository.existsByUserId("alice")).willReturn(false);
    }

    @Test
    void requestWithGatewayHeadersIsAuthenticatedWithoutAnySessionOrBootstrap() throws Exception {
        mockMvc.perform(get("/api/v1/auth/me")
                .header("X-Auth-Request-User", "alice")
                .header("X-Forwarded-Email", "alice@example.com"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.code").value(0))
            .andExpect(jsonPath("$.data.userId").value("alice"))
            .andExpect(jsonPath("$.data.oauthProvider").value("forward-auth"));

        ArgumentCaptor<OAuthClaims> claims = ArgumentCaptor.forClass(OAuthClaims.class);
        then(oauthLoginFlowService).should().authenticate(claims.capture());
        assertThat(claims.getValue().provider()).isEqualTo("forward-auth");
        assertThat(claims.getValue().subject()).isEqualTo("alice");
        assertThat(claims.getValue().email()).isEqualTo("alice@example.com");
    }

    @Test
    void protectedEndpointWithoutGatewayHeadersRemainsAnonymous() throws Exception {
        mockMvc.perform(get("/api/v1/auth/me"))
            .andExpect(status().isUnauthorized())
            .andExpect(jsonPath("$.code").value(401));
    }
}
