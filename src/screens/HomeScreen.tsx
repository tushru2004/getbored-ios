import React, {useCallback, useState} from 'react';
import {
    ActivityIndicator,
    Pressable,
    RefreshControl,
    SafeAreaView,
    ScrollView,
    StyleSheet,
    Text,
    TextInput,
    View,
} from 'react-native';

import {AccountSheet} from '../components/AccountSheet';
import {ErrorBoundary} from '../components/ErrorBoundary';
import {StillWaterRings} from '../components/StillWaterRings';
import {AccountState} from '../hooks/useAccount';
import {useDeviceRegistrationAndRuleSync} from '../hooks/useDeviceRegistrationAndRuleSync';
import {DeviceRegistrationState} from '../hooks/useDeviceRegistration';
import {FilterListSyncState} from '../hooks/useFilterListSync';
import {FilterStatusState, useFilterStatus} from '../hooks/useFilterStatus';
import {SyncSummary} from '../native/types';
import {colors, hardShadow, spacing, typography} from '../theme';
import {ActiveRulesScreen} from './ActiveRulesScreen';
import {ActivationScreen} from './ActivationScreen';

// ─── Home status derivation ────────────────────────────────────────────────

type HomeStatus = {
    word: string;
    color: string;
    variant: 'closed' | 'open';
    substance: string;
    showEnable: boolean;
};

function countLabel(count: number, singular: string, plural: string): string {
    if (count === 1) {
        return `1 ${singular}`;
    }
    return `${count} ${plural}`;
}

function formatSyncTime(syncedAtMs: number): string {
    return new Date(syncedAtMs).toLocaleTimeString([], {
        hour: 'numeric',
        minute: '2-digit',
    });
}

/**
 * The quiet line under the state word, in precedence order. A successful
 * sync returns '' — its counts render as the stat pair instead, and its
 * timestamp lives in the footer whisper.
 *
 * Only reached from deriveHomeStatus's 'active' filter branch. Registration
 * outranks sync so the one-time "Connecting…" is never masked by a stale
 * sync line:
 *
 *   registration 'saving'      → "Connecting this iPhone…"
 *   sync 'syncing'             → "Syncing…"
 *   sync 'success'             → ''  (stat pair + footer carry the detail)
 *   sync 'notRegistered'       → "Waiting to connect…"
 *   sync 'error'               → sync.message
 *   anything else (idle, …)    → ''
 */
function substanceLine(
    sync: FilterListSyncState,
    registration: DeviceRegistrationState,
): string {
    if (registration.kind === 'saving') {
        return 'Connecting this iPhone…';
    }
    if (sync.kind === 'syncing') {
        return 'Syncing…';
    }
    if (sync.kind === 'success') {
        return '';
    }
    if (sync.kind === 'notRegistered') {
        return 'Waiting to connect…';
    }
    if (sync.kind === 'error') {
        return sync.message;
    }
    return '';
}

/** Keep the compact account row useful for both password usernames and legacy
 * Apple relay addresses. The full account label stays visible in the sheet. */
function displayAccountLabel(accountLabel?: string): string {
if (!accountLabel) {
return 'Signed in';
}
if (accountLabel.endsWith('@privaterelay.appleid.com')) {
return 'Hidden Apple email';
}
return accountLabel;
}

// ─── Stat pair (what the last sync applied) ────────────────────────────────

/** Tapping the counts answers the obvious follow-up — "blocked WHAT?" —
 * by opening the Active Rules list. */
const StatPair: React.FC<{summary: SyncSummary; onPress: () => void}> = ({
summary,
onPress,
}) => {
const sitesCaption = summary.sites === 1 ? 'site blocked' : 'sites blocked';
const appsCaption =
summary.blockedApps === 1 ? 'app blocked' : 'apps blocked';
const hasBlockedApps = summary.blockedApps > 0;

return (
<Pressable
onPress={onPress}
style={({pressed}) => [styles.statPair, pressed && styles.pressedDim]}>
<View style={styles.stat}>
<Text style={styles.statNum}>{summary.sites}</Text>
<Text style={styles.statCap}>{sitesCaption}</Text>
</View>
{hasBlockedApps && (
<View style={[styles.stat, styles.statAfter]}>
<Text style={styles.statNum}>{summary.blockedApps}</Text>
<Text style={styles.statCap}>{appsCaption}</Text>
</View>
)}
</Pressable>
);
};

/**
 * Collapses filter status + sync + registration into the one answer the top
 * half of the screen exists to give. Subscription lapse and a disabled
 * filter both read as "Paused" — in both cases the truth is: not filtering.
 *
 * Precedence (first match wins — a subscription lapse outranks everything,
 * then filter loading/error, then the filter's own kind):
 *
 *   deriveHomeStatus(filter, sync, registration)
 *       │
 *       ├── sync 'subscriptionRequired'      → "Paused"    (warning, no Enable)
 *       ├── filter 'loading'                 → "Checking…" (neutral)
 *       ├── filter 'error'                   → "Unknown"   (neutral, filter.message)
 *       └── filter 'ready' → filter.status.filter.kind
 *               │
 *               ├── 'inactive'  → "Paused"   (warning, showEnable = true)
 *               ├── 'active'    → "GetBored" (success; substance = substanceLine(...))
 *               └── otherwise   → "Checking…"(neutral fallback)
 *
 * Only the 'inactive' branch sets showEnable — it's the one Paused state the
 * user can fix in-app; a subscription lapse is fixed off-device.
 */
function deriveHomeStatus(
    filter: FilterStatusState,
    sync: FilterListSyncState,
    registration: DeviceRegistrationState,
): HomeStatus {
    if (sync.kind === 'subscriptionRequired') {
        return {
            word: 'Paused',
            color: colors.warning,
            variant: 'open',
            substance: 'Subscription required — filtering stopped',
            showEnable: false,
        };
    }
    if (filter.kind === 'loading') {
        return {
            word: 'Checking…',
            color: colors.neutral,
            variant: 'closed',
            substance: '',
            showEnable: false,
        };
    }
    if (filter.kind === 'error') {
        return {
            word: 'Unknown',
            color: colors.neutral,
            variant: 'open',
            substance: filter.message,
            showEnable: false,
        };
    }
    const filterKind = filter.status.filter.kind;
    if (filterKind === 'inactive') {
        return {
            word: 'Paused',
            color: colors.warning,
            variant: 'open',
            substance: 'The content filter is turned off',
            showEnable: true,
        };
    }
    if (filterKind === 'active') {
        return {
            // The good state IS the brand: the wordmark itself sits under the
            // settled rings. Attention states keep plain state words.
            word: 'GetBored',
            color: colors.success,
            variant: 'closed',
            substance: substanceLine(sync, registration),
            showEnable: false,
        };
    }
    return {
        word: 'Checking…',
        color: colors.neutral,
        variant: 'closed',
        substance: '',
        showEnable: false,
    };
}

function homeStatusEyebrow(status: HomeStatus): string {
    if (status.word === 'GetBored') {
        return 'This iPhone · quiet';
    }
    if (status.word === 'Paused') {
        return 'This iPhone · attention';
    }
    return 'This iPhone · status';
}

// ─── Shared brand masthead ──────────────────────────────────────────────────

const BrandMasthead: React.FC = () => (
    <View style={styles.brandMasthead}>
        <View>
            <View style={styles.brandWordmarkRow}>
                <Text style={styles.brandWordmark}>Get</Text>
                <Text style={[styles.brandWordmark, styles.brandWordmarkAccent]}>
                    Bored.
                </Text>
            </View>
            <Text style={styles.brandTagline}>
                Bored minds{`\n`}go interesting places.
            </Text>
        </View>
        <StillWaterRings size={72} color={colors.surface} variant="closed" />
    </View>
);

// ─── Welcome (signed out / deleting) ───────────────────────────────────────

type WelcomeProps = {
    account: AccountState;
    onSignIn: (username: string, password: string) => Promise<void>;
    onSignUp: (username: string, password: string) => Promise<void>;
};

const Welcome: React.FC<WelcomeProps> = ({account, onSignIn, onSignUp}) => {
    const [mode, setMode] = useState<'login' | 'signup'>('login');
    const [username, setUsername] = useState('');
    const [password, setPassword] = useState('');
    const signingUp = mode === 'signup';
    const busy =
        account.kind === 'checking' ||
        account.kind === 'signingIn' ||
        account.kind === 'deleting';
    const isDeleting = account.kind === 'deleting';
    const valid = username.trim().length >= 3 && password.length >= 8;
    const authenticationDisabled = busy || !valid;
    const passwordAutoComplete = signingUp ? 'new-password' : 'current-password';
    const passwordTextContentType = signingUp ? 'newPassword' : 'password';
    const submitLabel = signingUp ? 'Create account' : 'Sign in';
    const modeSwitchLabel = signingUp
        ? 'Already have an account? Sign in'
        : 'Create a new account';
    /**
     * Normalizes the username once, then picks the account action matching the
     * visible form mode. The account hook owns its resulting loading and error
     * states, which return here through the `account` prop.
     *
     *   form submit → submit()
     *       ├── login  → onSignIn(normalizedUsername, password)
     *       └── signup → onSignUp(normalizedUsername, password)
     */
    const submit = useCallback(() => {
        const normalizedUsername = username.trim().toLowerCase();
        if (signingUp) {
            return onSignUp(normalizedUsername, password);
        }
        return onSignIn(normalizedUsername, password);
    }, [onSignIn, onSignUp, password, signingUp, username]);
    const submitFromKeyboardOrPress = useCallback(() => {
        if (!valid || busy) {
            return;
        }
        submit().catch(() => undefined);
    }, [busy, submit, valid]);

    return (
        <View style={styles.welcome}>
            <BrandMasthead />
            <View style={styles.welcomeBody}>
                {isDeleting && (
                    <Text style={styles.welcomeTagline}>Deleting your account…</Text>
                )}
                {account.kind === 'error' && (
                    <Text style={styles.welcomeError}>{account.message}</Text>
                )}
                <Text style={styles.authFieldLabel}>Username</Text>
                <TextInput
                    autoCapitalize="none"
                    autoComplete="username"
                    autoCorrect={false}
                    editable={!busy}
                    maxLength={64}
                    onChangeText={setUsername}
                    returnKeyType="next"
                    style={styles.authInput}
                    textContentType="username"
                    value={username}
                />
                <Text style={styles.authFieldLabel}>Password</Text>
                <TextInput
                    autoCapitalize="none"
                    autoComplete={passwordAutoComplete}
                    autoCorrect={false}
                    editable={!busy}
                    maxLength={128}
                    onChangeText={setPassword}
                    onSubmitEditing={submitFromKeyboardOrPress}
                    returnKeyType="done"
                    secureTextEntry
                    style={styles.authInput}
                    textContentType={passwordTextContentType}
                    value={password}
                />
                <Pressable
                    disabled={authenticationDisabled}
                    onPress={submitFromKeyboardOrPress}
                    style={({pressed}) => [
                        styles.authButton,
                        (pressed || authenticationDisabled) && styles.pressedDim,
                    ]}>
                    {busy ? (
                        <ActivityIndicator color="#FFFFFF" />
                    ) : (
                        <Text style={styles.authButtonText}>{submitLabel}</Text>
                    )}
                </Pressable>
                <Pressable
                    disabled={busy}
                    onPress={() =>
                        setMode(current => (current === 'login' ? 'signup' : 'login'))
                    }
                    style={styles.authModeButton}>
                    <Text style={styles.authModeText}>{modeSwitchLabel}</Text>
                </Pressable>
            </View>
        </View>
    );
};

// ─── Managed profile gate (activated accounts only) ───────────────────────

type ProfileGateProps = {
    filter: FilterStatusState;
    accountLabel?: string;
    onDownload: () => Promise<void>;
    onRefresh: () => void;
    onSignOut: () => void;
};

function profileGateCopy(checking: boolean, missing: boolean) {
    if (checking) {
        return {
            title: 'Checking protection…',
            detail: 'Looking for the managed GetBored filter profile on this iPhone.',
            eyebrow: 'This iPhone · checking',
        };
    }
    if (missing) {
        return {
            title: 'Protection missing',
            detail:
                'Download the profile, then open Settings → Profile Downloaded → Install.',
            eyebrow: 'This iPhone · needs attention',
        };
    }
    return {
        title: 'Unable to verify setup',
        detail:
            'GetBored could not read the managed filter profile. Check device management, then try again.',
        eyebrow: 'This iPhone · needs attention',
    };
}

const ProfileGate: React.FC<ProfileGateProps> = ({
    filter,
    accountLabel,
    onDownload,
    onRefresh,
    onSignOut,
}) => {
    const [downloading, setDownloading] = useState(false);
    const [downloadError, setDownloadError] = useState<string | null>(null);
    const checking = filter.kind === 'loading';
    const missing =
        filter.kind === 'ready' && filter.status.profile.kind === 'missing';
    const {title, detail, eyebrow} = profileGateCopy(checking, missing);
    /**
     * Requests the native profile download and retains a failure in this gate.
     * Downloading opens the system browser; the user completes installation in
     * Settings, then uses Check Again to refresh native filter status.
     *
     *   Download press → onDownload() → system browser
     *       │
     *       └── rejection → downloadError → inline error text
     */
    const download = useCallback(async () => {
        setDownloading(true);
        setDownloadError(null);
        try {
            await onDownload();
        } catch (error: unknown) {
            setDownloadError(error instanceof Error ? error.message : String(error));
        } finally {
            setDownloading(false);
        }
    }, [onDownload]);

    let profileAction: React.ReactNode;
    if (checking) {
        profileAction = (
            <ActivityIndicator
                color={colors.label}
                style={styles.profileGateActivity}
            />
        );
    } else if (missing) {
        profileAction = (
            <>
                <Pressable
                    disabled={downloading}
                    onPress={download}
                    style={({pressed}) => [
                        styles.cta,
                        styles.profileGateRefresh,
                        (pressed || downloading) && styles.pressedDim,
                    ]}>
                    {downloading ? (
                        <ActivityIndicator color={colors.label} />
                    ) : (
                        <Text style={styles.ctaText}>Download &amp; Install Profile</Text>
                    )}
                </Pressable>
                <Pressable onPress={onRefresh} style={styles.profileGateCheckAgain}>
                    <Text style={styles.profileGateCheckAgainText}>Check Again</Text>
                </Pressable>
            </>
        );
    } else {
        profileAction = (
            <Pressable
                onPress={onRefresh}
                style={({pressed}) => [
                    styles.cta,
                    styles.profileGateRefresh,
                    pressed && styles.pressedDim,
                ]}>
                <Text style={styles.ctaText}>Check Again</Text>
            </Pressable>
        );
    }

    return (
        <View style={styles.profileGate}>
            <BrandMasthead />
            <View style={styles.profileGateBody}>
                <StillWaterRings
                    size={112}
                    color={checking ? colors.neutral : colors.warning}
                    variant="open"
                />
                <Text style={styles.profileGateEyebrow}>{eyebrow}</Text>
                <Text style={styles.profileGateTitle}>{title}</Text>
                <Text style={styles.profileGateDetail}>{detail}</Text>
                <View style={styles.profileGateIdentity}>
                    <Text style={styles.profileGateIdentityLabel}>Signed-in account</Text>
                    <Text selectable style={styles.profileGateIdentityValue}>
                        {accountLabel ?? 'Account unavailable'}
                    </Text>
                </View>
                {downloadError !== null && (
                    <Text style={styles.profileGateError}>{downloadError}</Text>
                )}
                {profileAction}
                <Pressable onPress={onSignOut} style={styles.profileGateSignOut}>
                    <Text style={styles.profileGateSignOutText}>Sign out</Text>
                </Pressable>
            </View>
        </View>
    );
};

// ─── Home ──────────────────────────────────────────────────────────────────

        /**
         * The app's single screen. useDeviceRegistrationAndRuleSync owns
         * account/registration/sync and
         * runs the auto-connect/auto-sync orchestration; this component only reads that
         * state to decide which of three top-level views to show, and hosts the two
         * modals.
         *
         * Top-level gating:
         *
         *   account.state.kind
         *       │
         *       ├── 'needsActivation' → <ActivationScreen>  (redeem a code)
         *       ├── 'signedIn'       → filter profile gate
         *       │       ├── profile installed → main dashboard
         *       │       └── missing/unknown   → <ProfileGate>
         *       ├── 'unavailable'    → main dashboard (legacy native build fallback)
         *       └── anything else (signedOut / checking / signingIn / deleting / error)
         *               └──→ <Welcome> — username/password sign-in or account creation.
         *
         * Main dashboard:
         *
         *   pull-to-refresh (RefreshControl) → onPullRefresh()
         *       └──→ Promise.all([sync(), refreshStatus()])  ← 'pulling' guards the spinner
         *
         *   deriveHomeStatus(...) chooses the status; showStatPair (active + last sync succeeded)
         *   swaps the rings/word block for the tappable StatPair → opens the rules modal.
         *
         * Modals (rendered always, toggled by local state; both live OUTSIDE the
         * showMain branch so a sign-out mid-sheet still animates them closed):
         *
         *   showAccount ── openAccount() also calls refreshAccount(false) to retry the
         *       │          optional /api/me enrichment without flashing 'checking'
         *       └──→ <AccountSheet>  (sign out / delete account)
         *   showRules ──→ <ActiveRulesScreen>  (read-only rules list)
         */
        export const HomeScreen: React.FC = () => {
            const {account, registration, filterSync} =
                useDeviceRegistrationAndRuleSync();
            const filterStatus = useFilterStatus();
            const [showAccount, setShowAccount] = useState(false);
            const [showRules, setShowRules] = useState(false);
            const [pulling, setPulling] = useState(false);

            const {sync} = filterSync;
            const {refresh: refreshAccount} = account;
            const {
                refresh: refreshStatus,
                enable,
                downloadProfile,
                enableError,
            } = filterStatus;

            const onPullRefresh = useCallback(async () => {
                setPulling(true);
                try {
                    await Promise.all([sync(), refreshStatus()]);
                } finally {
                    setPulling(false);
                }
            }, [sync, refreshStatus]);

            const signedInAccount =
                account.state.kind === 'signedIn' ? account.state : null;
            const signedIn = signedInAccount !== null;
            const reviewDemo = signedInAccount?.reviewDemo ?? false;
            const needsActivation = account.state.kind === 'needsActivation';
            const accountAbsent = account.state.kind === 'unavailable';
            const profileInstalled =
                filterStatus.state.kind === 'ready' &&
                filterStatus.state.status.profile.kind === 'installed';
            const showProfileGate = signedIn && !reviewDemo && !profileInstalled;
            const showMain =
                accountAbsent || (signedIn && (reviewDemo || profileInstalled));

            const homeStatus: HomeStatus = reviewDemo
                ? {
                        word: 'Demo mode',
                        color: colors.neutral,
                        variant: 'open',
                        substance: 'Live filtering requires a supervised iPhone.',
                        showEnable: false,
                    }
                : deriveHomeStatus(
                        filterStatus.state,
                        filterSync.state,
                        registration.state,
                    );
            const accountLabel =
                account.state.kind === 'signedIn' ||
                account.state.kind === 'needsActivation'
                    ? account.state.accountLabel
                    : undefined;
            const syncSuccess =
                filterSync.state.kind === 'success' ? filterSync.state : null;
            const showStatPair = homeStatus.word === 'GetBored' && syncSuccess !== null;
            const rulesValue = syncSuccess
                ? countLabel(syncSuccess.summary.sites, 'site', 'sites')
                : '—';
            const footerText = syncSuccess
                ? `Synced automatically · ${formatSyncTime(syncSuccess.syncedAtMs)}`
                : 'This iPhone syncs automatically.';
            const heroEyebrow = homeStatusEyebrow(homeStatus);
            /**
             * A failed "Turn Filtering On" outranks the generic Paused copy: the
             * ticket shows WHY it failed, and stays until the user retries (the
             * status poll can't clear it — see useFilterStatus.enableError).
             */
            const warningText = enableError ?? homeStatus.substance;
            const showWarningTicket =
                enableError !== null ||
                (homeStatus.word === 'Paused' && homeStatus.substance !== '');
            const openAccount = useCallback(() => {
                setShowAccount(true);
                /**
                 * Keep the existing signed-in UI in place while retrying the optional
                 * `/api/me` enrichment. A transient launch-time failure should not leave
                 * the account sheet showing a blank email for the rest of the session.
                 */
                refreshAccount(false);
            }, [refreshAccount]);

            let gatedContent: React.ReactNode = null;
            if (!showMain) {
                if (needsActivation) {
                    gatedContent = (
                        <ActivationScreen
                            accountLabel={accountLabel}
                            onActivate={account.redeemActivationCode}
                            onSignOut={account.signOut}
                        />
                    );
                } else if (showProfileGate) {
                    gatedContent = (
                        <ProfileGate
                            filter={filterStatus.state}
                            accountLabel={accountLabel}
                            onDownload={downloadProfile}
                            onRefresh={refreshStatus}
                            onSignOut={account.signOut}
                        />
                    );
                } else {
                    gatedContent = (
                        <Welcome
                            account={account.state}
                            onSignIn={account.signIn}
                            onSignUp={account.signUp}
                        />
                    );
                }
            }

            return (
                <SafeAreaView style={styles.root}>
                    <ErrorBoundary>
                        {gatedContent}

                        {showMain && (
                            <ScrollView
                                contentContainerStyle={styles.scroll}
                                refreshControl={
                                    <RefreshControl refreshing={pulling} onRefresh={onPullRefresh} />
                                }>
                                <BrandMasthead />
                                {!showStatPair && (
                                    <View style={styles.hero}>
                                        <StillWaterRings
                                            size={112}
                                            color={homeStatus.color}
                                            variant={homeStatus.variant}
                                        />
                                        <View style={styles.heroCopy}>
                                            <Text style={styles.heroEyebrow}>{heroEyebrow}</Text>
                                            <Text
                                                style={[
                                                    styles.stateWord,
                                                    {color: homeStatusWordColor(homeStatus)},
                                                ]}>
                                                {homeStatus.word}
                                            </Text>
                                            {!showWarningTicket && homeStatus.substance !== '' && (
                                                <Text style={styles.substance}>{homeStatus.substance}</Text>
                                            )}
                                        </View>
                                    </View>
                                )}

                                {showStatPair && syncSuccess && (
                                    <StatPair
                                        summary={syncSuccess.summary}
                                        onPress={() => setShowRules(true)}
                                    />
                                )}

                                {showWarningTicket && (
                                    <View style={styles.warningTicket}>
                                        <Text style={styles.warningTicketText}>{warningText}</Text>
                                    </View>
                                )}

                                {homeStatus.showEnable && (
                                    <Pressable
                                        onPress={enable}
                                        style={({pressed}) => [
                                            styles.cta,
                                            pressed && styles.pressedDim,
                                        ]}>
                                        <Text style={styles.ctaText}>Turn Filtering On</Text>
                                    </Pressable>
                                )}

                                <View style={styles.rows}>
                                    {signedIn && (
                                        <Pressable
                                            style={({pressed}) => [
                                                styles.row,
                                                pressed && styles.pressedDim,
                                            ]}
                                            onPress={openAccount}>
                                            <Text style={styles.rowLabel}>Account</Text>
                                            <Text style={styles.rowValue} numberOfLines={1}>
                                                {displayAccountLabel(accountLabel)}
                                            </Text>
                                            <Text style={styles.chevron}>›</Text>
                                        </Pressable>
                                    )}
                                    <Pressable
                                        style={({pressed}) => [
                                            styles.row,
                                            pressed && styles.pressedDim,
                                        ]}
                                        onPress={() => setShowRules(true)}>
                                        <Text style={styles.rowLabel}>Active rules</Text>
                                        <Text style={styles.rowValue}>{rulesValue}</Text>
                                        <Text style={styles.chevron}>›</Text>
                                    </Pressable>
                                </View>

                                <Text style={styles.footerWhisper}>{footerText}</Text>
                            </ScrollView>
                        )}
                    </ErrorBoundary>

                    <AccountSheet
                        visible={showAccount}
                        onClose={() => setShowAccount(false)}
                        accountLabel={accountLabel}
                        registration={registration.state}
                        onSignOut={account.signOut}
                        onDeleteAccount={account.deleteAccount}
                    />
                    <ActiveRulesScreen
                        visible={showRules}
                        onClose={() => setShowRules(false)}
                    />
                </SafeAreaView>
            );
        };

function homeStatusWordColor(status: HomeStatus): string {
    if (status.word === 'Paused') {
        return colors.warning;
    }
    return colors.label;
}

const styles = StyleSheet.create({
    root: {
        flex: 1,
        backgroundColor: colors.background,
    },
    scroll: {
        flexGrow: 1,
        paddingHorizontal: spacing.xl,
        paddingBottom: spacing.xxl,
    },
    hero: {
        flexDirection: 'row',
        alignItems: 'center',
        paddingTop: spacing.xxl + spacing.sm,
        paddingBottom: spacing.xl,
        gap: spacing.lg,
        borderBottomWidth: 2,
        borderBottomColor: colors.label,
    },
    heroCopy: {
        flex: 1,
    },
    heroEyebrow: {
        ...typography.eyebrow,
        color: colors.label,
    },
    stateWord: {
        ...typography.hero,
        marginTop: spacing.sm,
    },
    substance: {
        ...typography.subhead,
        fontSize: 12,
        lineHeight: 17,
        color: colors.labelSecondary,
        fontVariant: ['tabular-nums'],
        marginTop: spacing.sm,
    },
    cta: {
        ...hardShadow,
        backgroundColor: colors.sun,
        borderWidth: 1,
        borderColor: colors.label,
        borderRadius: 0,
        alignItems: 'center',
        justifyContent: 'center',
        minHeight: 49,
        marginBottom: spacing.xl,
    },
    ctaText: {
        ...typography.eyebrow,
        color: colors.label,
    },
    warningTicket: {
        backgroundColor: colors.surface,
        borderLeftWidth: 4,
        borderLeftColor: colors.signal,
        paddingHorizontal: spacing.md,
        paddingVertical: spacing.md,
        marginTop: spacing.lg,
        marginBottom: spacing.lg,
    },
    warningTicketText: {
        ...typography.subhead,
        color: colors.label,
        lineHeight: 18,
    },
    rows: {
        borderTopWidth: 1,
        borderTopColor: colors.label,
        marginTop: spacing.xl,
    },
    row: {
        flexDirection: 'row',
        alignItems: 'center',
        gap: spacing.sm,
        paddingVertical: spacing.lg + 2,
        borderBottomWidth: StyleSheet.hairlineWidth,
        borderBottomColor: colors.separator,
    },
    rowLabel: {
        fontFamily: typography.display.fontFamily,
        fontSize: 16,
        fontWeight: '600',
        color: colors.label,
    },
    rowValue: {
        fontSize: 15,
        fontWeight: '400',
        // A step darker than labelSecondary so values don't read washed-out
        // next to the labels (iteration-02 mock).
        color: colors.labelSecondary,
        marginLeft: 'auto',
        maxWidth: 190,
        fontVariant: ['tabular-nums'],
    },
    chevron: {
        fontSize: 17,
        fontWeight: '400',
        color: colors.labelSecondary,
    },
    statPair: {
        ...hardShadow,
        flexDirection: 'row',
        backgroundColor: colors.surface,
        borderWidth: 1,
        borderColor: colors.label,
        marginTop: spacing.lg,
    },
    stat: {
        flex: 1,
        alignItems: 'center',
        justifyContent: 'center',
        minHeight: 76,
        paddingVertical: spacing.md,
    },
    statAfter: {
        borderLeftWidth: 1,
        borderLeftColor: colors.label,
    },
    statNum: {
        fontFamily: typography.display.fontFamily,
        fontSize: 29,
        fontWeight: '500',
        letterSpacing: -0.8,
        color: colors.label,
        fontVariant: ['tabular-nums'],
    },
    statCap: {
        marginTop: 2,
        ...typography.eyebrow,
        fontSize: 10,
        color: colors.labelSecondary,
    },
    footerWhisper: {
        ...typography.microFooter,
        color: colors.neutral,
        textAlign: 'center',
        marginTop: 'auto',
        paddingTop: spacing.xxl,
    },
    pressedDim: {
        opacity: 0.6,
    },

    // Brand masthead shared by the signed-out and signed-in home states.
    brandMasthead: {
        backgroundColor: colors.label,
        borderBottomWidth: 3,
        borderBottomColor: colors.sun,
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'space-between',
        minHeight: 124,
        paddingHorizontal: spacing.xl,
        paddingVertical: spacing.lg,
        marginHorizontal: -spacing.xl,
    },
    brandWordmark: {
        ...typography.wordmarkLarge,
        color: colors.surface,
    },
    brandWordmarkRow: {
        alignItems: 'baseline',
        flexDirection: 'row',
        gap: 4,
    },
    brandWordmarkAccent: {
        color: colors.sun,
        transform: [{translateY: 3}, {rotate: '-2deg'}],
    },
    brandTagline: {
        ...typography.microFooter,
        color: colors.surface,
        lineHeight: 16,
        marginTop: spacing.md,
    },

    // Welcome
    welcome: {
        flex: 1,
        paddingHorizontal: spacing.xl,
    },
    welcomeBody: {
        flex: 1,
        justifyContent: 'center',
        paddingBottom: spacing.xxl,
    },
    welcomeTagline: {
        fontFamily: typography.display.fontFamily,
        fontSize: 18,
        fontStyle: 'italic',
        lineHeight: 22,
        color: colors.labelSecondary,
        textAlign: 'center',
        marginTop: spacing.sm,
    },
    welcomeError: {
        ...typography.subhead,
        color: colors.danger,
        textAlign: 'center',
        marginTop: spacing.md,
    },
    authFieldLabel: {
        ...typography.eyebrow,
        color: colors.label,
        marginTop: spacing.md,
    },
    authInput: {
        minHeight: 48,
        borderWidth: 1,
        borderColor: colors.label,
        backgroundColor: colors.surface,
        color: colors.label,
        fontFamily: typography.eyebrow.fontFamily,
        fontSize: 15,
        paddingHorizontal: spacing.md,
        marginTop: spacing.sm,
    },
    authButton: {
        alignSelf: 'stretch',
        alignItems: 'center',
        justifyContent: 'center',
        minHeight: 50,
        backgroundColor: '#0E1211',
        borderRadius: 0,
        paddingVertical: spacing.lg,
        marginTop: spacing.xl,
    },
    authButtonText: {
        ...typography.body,
        fontSize: 16,
        color: '#FFFFFF',
    },
    authModeButton: {
        alignItems: 'center',
        padding: spacing.md,
    },
    authModeText: {
        ...typography.body,
        color: colors.labelSecondary,
        textDecorationLine: 'underline',
    },

    // Profile gate
    profileGate: {
        flex: 1,
        paddingHorizontal: spacing.xl,
    },
    profileGateBody: {
        flex: 1,
        alignItems: 'center',
        justifyContent: 'center',
        paddingBottom: spacing.xxl,
    },
    profileGateEyebrow: {
        ...typography.eyebrow,
        color: colors.label,
        marginTop: spacing.lg,
    },
    profileGateTitle: {
        ...typography.hero,
        color: colors.warning,
        marginTop: spacing.sm,
        textAlign: 'center',
    },
    profileGateDetail: {
        ...typography.subhead,
        color: colors.labelSecondary,
        lineHeight: 20,
        marginTop: spacing.md,
        maxWidth: 320,
        textAlign: 'center',
    },
    profileGateIdentity: {
        alignSelf: 'stretch',
        borderTopWidth: StyleSheet.hairlineWidth,
        borderTopColor: colors.separator,
        marginTop: spacing.lg,
        paddingTop: spacing.md,
    },
    profileGateIdentityLabel: {
        ...typography.eyebrow,
        color: colors.labelSecondary,
        marginTop: spacing.sm,
        textAlign: 'center',
    },
    profileGateIdentityValue: {
        ...typography.caption,
        color: colors.label,
        marginTop: 3,
        textAlign: 'center',
    },
    profileGateActivity: {
        marginTop: spacing.xl,
    },
    profileGateError: {
        ...typography.body,
        color: colors.warning,
        marginTop: spacing.md,
        textAlign: 'center',
    },
    profileGateRefresh: {
        alignSelf: 'stretch',
        marginBottom: 0,
        marginTop: spacing.xl,
    },
    profileGateCheckAgain: {
        paddingHorizontal: spacing.lg,
        paddingVertical: spacing.md,
        marginTop: spacing.sm,
    },
    profileGateCheckAgainText: {
        ...typography.body,
        color: colors.label,
    },
    profileGateSignOut: {
        paddingHorizontal: spacing.lg,
        paddingVertical: spacing.md,
        marginTop: spacing.md,
    },
    profileGateSignOutText: {
        ...typography.body,
        color: colors.labelSecondary,
    },
});
