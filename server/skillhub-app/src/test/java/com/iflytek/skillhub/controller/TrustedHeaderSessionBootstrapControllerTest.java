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
import org.springframework.mock.web.MockHttpSession;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.web.servlet.MockMvc;

import static org.assertj.core.api.Assertions.assertThat;
import static org.hamcrest.Matchers.hasItem;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.BDDMockito.given;
import static org.mockito.BDDMockito.then;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Verifies the forward-auth trusted-header wiring end to end: the gateway headers are turned into
 * claims, the shared login flow provisions the principal, and the browser leaves with a first-party
 * SkillHub session.
 */
@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("test")
@TestPropertySource(properties = {
    "skillhub.auth.session-bootstrap.enabled=true",
    "skillhub.auth.trusted-header.enabled=true",
    "skillhub.auth.trusted-header.display-name=Corp Gateway"
})
class TrustedHeaderSessionBootstrapControllerTest {

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
    void localAuthEnabled() {
        // AuthMethodCatalog and AuthMeResponseAssembler both read the local-auth settings snapshot.
        given(localAuthSettingsService.current()).willReturn(new LocalAuthSettings(1L, true, true, 0L, null));
    }

    @Test
    void methodsCatalogAdvertisesTheTrustedHeaderProvider() throws Exception {
        mockMvc.perform(get("/api/v1/auth/methods"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.data[*].provider").value(hasItem("forward-auth")))
            .andExpect(jsonPath("$.data[*].methodType").value(hasItem("SESSION_BOOTSTRAP")));
    }

    @Test
    void bootstrapExchangesGatewayHeadersForAPlatformSession() throws Exception {
        given(oauthLoginFlowService.authenticate(any()))
            .willReturn(new PlatformPrincipal(
                "alice", "alice", "alice@example.com", null, "forward-auth", Set.of("USER")));
        given(userAccountRepository.findById("alice"))
            .willReturn(Optional.of(new UserAccount("alice", "alice", "alice@example.com", null)));
        given(userRoleBindingRepository.findByUserId("alice")).willReturn(List.of());
        given(namespaceMemberRepository.findByUserId("alice")).willReturn(List.of());
        given(localCredentialRepository.existsByUserId("alice")).willReturn(false);

        MockHttpSession session = (MockHttpSession) mockMvc.perform(post("/api/v1/auth/session/bootstrap")
                .with(csrf())
                .header("X-Auth-Request-User", "alice")
                .header("X-Forwarded-Email", "alice@example.com")
                .contentType("application/json")
                .content("""
                    {"provider":"forward-auth"}
                    """))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.code").value(0))
            .andExpect(jsonPath("$.data.userId").value("alice"))
            .andReturn()
            .getRequest()
            .getSession(false);

        ArgumentCaptor<OAuthClaims> claims = ArgumentCaptor.forClass(OAuthClaims.class);
        then(oauthLoginFlowService).should().authenticate(claims.capture());
        assertThat(claims.getValue().provider()).isEqualTo("forward-auth");
        assertThat(claims.getValue().subject()).isEqualTo("alice");
        assertThat(claims.getValue().email()).isEqualTo("alice@example.com");
        assertThat(claims.getValue().emailVerified()).isTrue();

        mockMvc.perform(get("/api/v1/auth/me").session(session))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.data.userId").value("alice"))
            .andExpect(jsonPath("$.data.oauthProvider").value("forward-auth"));
    }

    @Test
    void bootstrapWithoutGatewayHeadersStaysAnonymous() throws Exception {
        mockMvc.perform(post("/api/v1/auth/session/bootstrap")
                .with(csrf())
                .contentType("application/json")
                .content("""
                    {"provider":"forward-auth"}
                    """))
            .andExpect(status().isUnauthorized())
            .andExpect(jsonPath("$.code").value(401));
    }
}
