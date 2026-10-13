package com.iflytek.skillhub.auth.trustedheader;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

/**
 * Configuration for trusting identity headers injected by an upstream
 * forward-auth gateway.
 *
 * <p>Disabled by default. Enabling it means the platform treats the configured
 * headers as an already-verified identity, so the deployment must guarantee
 * that only the trusted gateway can set them.
 */
@Component
@ConfigurationProperties(prefix = "skillhub.auth.trusted-header")
public class TrustedHeaderAuthProperties {

    /**
     * Master switch for the trusted-header authenticator.
     */
    private boolean enabled = false;

    /**
     * When enabled, every request carrying the configured headers signs in
     * automatically through {@link TrustedHeaderAuthenticationFilter}, without any
     * login-page round trip. Requires {@link #enabled} as well.
     */
    private boolean perRequestAuthentication = false;

    /**
     * External provider code recorded on the identity binding. Keep it stable
     * once accounts exist, because changing it creates a new identity
     * coordinate.
     */
    private String providerCode = "forward-auth";

    /**
     * Login-page label exposed through {@code /api/v1/auth/methods}.
     */
    private String displayName = "Enterprise SSO";

    /**
     * Header carrying the stable external user identifier. Its value is used as
     * both the binding subject and the provider login name.
     */
    private String userHeader = "X-Auth-Request-User";

    /**
     * Header carrying the email address verified by the gateway. Optional: when
     * absent the account keeps no email.
     */
    private String emailHeader = "X-Forwarded-Email";

    /**
     * Header carrying the shared secret that proves the request reached the
     * application through the trusted gateway.
     */
    private String sharedSecretHeader = "X-Skillhub-Proxy-Secret";

    /**
     * Shared secret expected in {@link #sharedSecretHeader}. When blank, header
     * origin is not verified in the application and network isolation becomes
     * the only control; a warning is logged at first use.
     */
    private String sharedSecret = "";

    public boolean isEnabled() {
        return enabled;
    }

    public void setEnabled(boolean enabled) {
        this.enabled = enabled;
    }

    public boolean isPerRequestAuthentication() {
        return perRequestAuthentication;
    }

    public void setPerRequestAuthentication(boolean perRequestAuthentication) {
        this.perRequestAuthentication = perRequestAuthentication;
    }

    public String getProviderCode() {
        return providerCode;
    }

    public void setProviderCode(String providerCode) {
        this.providerCode = providerCode;
    }

    public String getDisplayName() {
        return displayName;
    }

    public void setDisplayName(String displayName) {
        this.displayName = displayName;
    }

    public String getUserHeader() {
        return userHeader;
    }

    public void setUserHeader(String userHeader) {
        this.userHeader = userHeader;
    }

    public String getEmailHeader() {
        return emailHeader;
    }

    public void setEmailHeader(String emailHeader) {
        this.emailHeader = emailHeader;
    }

    public String getSharedSecretHeader() {
        return sharedSecretHeader;
    }

    public void setSharedSecretHeader(String sharedSecretHeader) {
        this.sharedSecretHeader = sharedSecretHeader;
    }

    public String getSharedSecret() {
        return sharedSecret;
    }

    public void setSharedSecret(String sharedSecret) {
        this.sharedSecret = sharedSecret;
    }
}
