import React, {useCallback, useState} from 'react';
import {
  ActivityIndicator,
  Pressable,
  RefreshControl,
  SafeAreaView,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import {AccountSheet} from '../components/AccountSheet';
import {ErrorBoundary} from '../components/ErrorBoundary';
import {StillWaterRings} from '../components/StillWaterRings';
import {AccountState} from '../hooks/useAccount';
import {useConnectedApp} from '../hooks/useConnectedApp';
import {DeviceRegistrationState} from '../hooks/useDeviceRegistration';
import {FilterListSyncState} from '../hooks/useFilterListSync';
import {FilterStatusState, useFilterStatus} from '../hooks/useFilterStatus';
import {SyncSummary} from '../native/types';
import {colors, hardShadow, spacing, typography} from '../theme';
import {ActiveRulesScreen} from './ActiveRulesScreen';
import {ActivationScreen} from './ActivationScreen';

// ─── Hero derivation ───────────────────────────────────────────────────────

type Hero = {
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

/** Never show a private-relay address raw — it reads as gibberish. The full
 * address stays visible in the Account sheet. */
function displayEmail(email?: string): string {
  if (!email) {
    return 'Signed in';
  }
  if (email.endsWith('@privaterelay.appleid.com')) {
    return 'Hidden Apple email';
  }
  return email;
}

// ─── Stat pair (what the last sync applied) ────────────────────────────────

/** Tapping the counts answers the obvious follow-up — "blocked WHAT?" —
 * by opening the Active Rules list. */
const StatPair: React.FC<{summary: SyncSummary; onPress: () => void}> = ({
  summary,
  onPress,
}) => (
  <Pressable
    onPress={onPress}
    style={({pressed}) => [styles.statPair, pressed && styles.pressedDim]}>
    <View style={styles.stat}>
      <Text style={styles.statNum}>{summary.sites}</Text>
      <Text style={styles.statCap}>
        {summary.sites === 1 ? 'site blocked' : 'sites blocked'}
      </Text>
    </View>
    {summary.blockedApps > 0 && (
      <View style={[styles.stat, styles.statAfter]}>
        <Text style={styles.statNum}>{summary.blockedApps}</Text>
        <Text style={styles.statCap}>
          {summary.blockedApps === 1 ? 'app blocked' : 'apps blocked'}
        </Text>
      </View>
    )}
  </Pressable>
);

/**
 * Collapses filter status + sync + registration into the one answer the top
 * half of the screen exists to give. Subscription lapse and a disabled
 * filter both read as "Paused" — in both cases the truth is: not filtering.
 */
function deriveHero(
  filter: FilterStatusState,
  sync: FilterListSyncState,
  registration: DeviceRegistrationState,
): Hero {
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

function heroEyebrowFor(hero: Hero): string {
  if (hero.word === 'GetBored') {
    return 'This iPhone · quiet';
  }
  if (hero.word === 'Paused') {
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
    <StillWaterRings
      size={72}
      color={colors.surface}
      variant="closed"
    />
  </View>
);

// ─── Welcome (signed out / deleting) ───────────────────────────────────────

type WelcomeProps = {
  account: AccountState;
  onSignIn: () => void;
};

const Welcome: React.FC<WelcomeProps> = ({account, onSignIn}) => {
  const busy =
    account.kind === 'checking' ||
    account.kind === 'signingIn' ||
    account.kind === 'deleting';
  const tagline =
    account.kind === 'deleting'
      ? 'Deleting your account…'
      : 'Block the noise.\nKeep the calm.';

  return (
    <View style={styles.welcome}>
      <BrandMasthead />
      <View style={styles.welcomeBody}>
        <Text style={styles.welcomeTagline}>{tagline}</Text>
        {account.kind === 'error' && (
          <Text style={styles.welcomeError}>{account.message}</Text>
        )}
        <Pressable
          disabled={busy}
          onPress={onSignIn}
          style={({pressed}) => [
            styles.appleButton,
            (pressed || busy) && styles.pressedDim,
          ]}>
          {busy ? (
            <ActivityIndicator color="#FFFFFF" />
          ) : (
            <Text style={styles.appleButtonText}>Sign in with Apple</Text>
          )}
        </Pressable>
        <Text style={styles.welcomeLegal}>
          One account. Rules managed from your admin.
        </Text>
      </View>
    </View>
  );
};

// ─── Home ──────────────────────────────────────────────────────────────────

export const HomeScreen: React.FC = () => {
  const {account, registration, filterSync} = useConnectedApp();
  const filterStatus = useFilterStatus();
  const [showAccount, setShowAccount] = useState(false);
  const [showRules, setShowRules] = useState(false);
  const [pulling, setPulling] = useState(false);

  const {sync} = filterSync;
  const {refresh: refreshAccount} = account;
  const {refresh: refreshStatus, enable} = filterStatus;

  const onPullRefresh = useCallback(async () => {
    setPulling(true);
    try {
      await Promise.all([sync(), refreshStatus()]);
    } finally {
      setPulling(false);
    }
  }, [sync, refreshStatus]);

  const signedIn = account.state.kind === 'signedIn';
  const needsActivation = account.state.kind === 'needsActivation';
  const accountAbsent = account.state.kind === 'unavailable';
  const showMain = signedIn || accountAbsent;

  const hero = deriveHero(
    filterStatus.state,
    filterSync.state,
    registration.state,
  );
  const accountEmail =
    account.state.kind === 'signedIn' || account.state.kind === 'needsActivation'
      ? account.state.email
      : undefined;
  const syncSuccess =
    filterSync.state.kind === 'success' ? filterSync.state : null;
  const showStatPair = hero.word === 'GetBored' && syncSuccess !== null;
  const rulesValue = syncSuccess
    ? countLabel(syncSuccess.summary.sites, 'site', 'sites')
    : '—';
  const footerText = syncSuccess
    ? `Synced automatically · ${formatSyncTime(syncSuccess.syncedAtMs)}`
    : 'This iPhone syncs automatically.';
  const heroEyebrow = heroEyebrowFor(hero);
  const showWarningTicket = hero.word === 'Paused' && hero.substance !== '';
  const openAccount = useCallback(() => {
    setShowAccount(true);
    // Keep the existing signed-in UI in place while retrying the optional
    // `/api/me` enrichment. A transient launch-time failure should not leave
    // the account sheet showing a blank email for the rest of the session.
    refreshAccount(false);
  }, [refreshAccount]);

  return (
    <SafeAreaView style={styles.root}>
      <ErrorBoundary>
        {!showMain && (
          needsActivation ? (
            <ActivationScreen
              accountLabel={accountEmail}
              onActivate={account.redeemActivationCode}
              onSignOut={account.signOut}
            />
          ) : (
            <Welcome account={account.state} onSignIn={account.signIn} />
          )
        )}

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
                  color={hero.color}
                  variant={hero.variant}
                />
                <View style={styles.heroCopy}>
                  <Text style={styles.heroEyebrow}>{heroEyebrow}</Text>
                  <Text style={[styles.stateWord, {color: heroWordColor(hero)}]}>
                    {hero.word}
                  </Text>
                  {!showWarningTicket && hero.substance !== '' && (
                    <Text style={styles.substance}>{hero.substance}</Text>
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
                <Text style={styles.warningTicketText}>{hero.substance}</Text>
              </View>
            )}

            {hero.showEnable && (
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
                    {displayEmail(accountEmail)}
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
        email={accountEmail}
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

function heroWordColor(hero: Hero): string {
  if (hero.word === 'Paused') {
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
  appleButton: {
    alignSelf: 'stretch',
    alignItems: 'center',
    justifyContent: 'center',
    minHeight: 50,
    backgroundColor: '#0E1211',
    borderRadius: 0,
    paddingVertical: spacing.lg,
    marginTop: spacing.xl,
  },
  appleButtonText: {
    ...typography.body,
    fontSize: 16,
    color: '#FFFFFF',
  },
  welcomeLegal: {
    ...typography.microFooter,
    fontSize: 10,
    color: colors.neutral,
    marginTop: spacing.md,
  },
});
