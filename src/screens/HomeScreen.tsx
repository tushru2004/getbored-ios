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
import {colors, radius, spacing, typography} from '../theme';
import {ActiveRulesScreen} from './ActiveRulesScreen';

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

function summaryLine(summary: SyncSummary, syncedAtMs: number): string {
  const parts = [countLabel(summary.sites, 'site blocked', 'sites blocked')];
  if (summary.blockedApps > 0) {
    parts.push(countLabel(summary.blockedApps, 'app blocked', 'apps blocked'));
  }
  const time = new Date(syncedAtMs).toLocaleTimeString([], {
    hour: 'numeric',
    minute: '2-digit',
  });
  parts.push(`synced ${time}`);
  return parts.join(' · ');
}

/** The quiet line under the state word, in precedence order. */
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
    return summaryLine(sync.summary, sync.syncedAtMs);
  }
  if (sync.kind === 'notRegistered') {
    return 'Waiting to connect…';
  }
  if (sync.kind === 'error') {
    return sync.message;
  }
  return '';
}

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
      word: 'Protected',
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
      <StillWaterRings size={140} color={colors.info} variant="closed" />
      <Text style={styles.welcomeWordmark}>GetBored</Text>
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
  const accountAbsent = account.state.kind === 'unavailable';
  const showMain = signedIn || accountAbsent;

  const hero = deriveHero(filterStatus.state, filterSync.state, registration.state);
  const accountEmail =
    account.state.kind === 'signedIn' ? account.state.email : undefined;
  const connected = registration.state.kind === 'registered';
  const rulesValue =
    filterSync.state.kind === 'success'
      ? countLabel(filterSync.state.summary.sites, 'site', 'sites')
      : '—';

  return (
    <SafeAreaView style={styles.root}>
      <ErrorBoundary>
        {!showMain && (
          <Welcome account={account.state} onSignIn={account.signIn} />
        )}

        {showMain && (
          <ScrollView
            contentContainerStyle={styles.scroll}
            refreshControl={
              <RefreshControl refreshing={pulling} onRefresh={onPullRefresh} />
            }>
            <Text style={styles.wordmark}>GetBored</Text>

            <View style={styles.hero}>
              <StillWaterRings size={120} color={hero.color} variant={hero.variant} />
              <Text style={[styles.stateWord, {color: heroWordColor(hero)}]}>
                {hero.word}
              </Text>
              {hero.substance !== '' && (
                <Text style={styles.substance}>{hero.substance}</Text>
              )}
            </View>

            {hero.showEnable && (
              <Pressable
                onPress={enable}
                style={({pressed}) => [styles.cta, pressed && styles.pressedDim]}>
                <Text style={styles.ctaText}>Turn Filtering On</Text>
              </Pressable>
            )}

            <View style={styles.rows}>
              {signedIn && (
                <Pressable
                  style={({pressed}) => [styles.row, pressed && styles.pressedDim]}
                  onPress={() => setShowAccount(true)}>
                  <View
                    style={[
                      styles.dot,
                      {backgroundColor: connected ? colors.success : colors.warning},
                    ]}
                  />
                  <Text style={styles.rowLabel}>Account</Text>
                  <Text style={styles.rowValue} numberOfLines={1}>
                    {accountEmail ?? 'Signed in'}
                  </Text>
                  <Text style={styles.chevron}>›</Text>
                </Pressable>
              )}
              <Pressable
                style={({pressed}) => [styles.row, pressed && styles.pressedDim]}
                onPress={() => setShowRules(true)}>
                <Text style={styles.rowLabel}>Active rules</Text>
                <Text style={styles.rowValue}>{rulesValue}</Text>
                <Text style={styles.chevron}>›</Text>
              </Pressable>
            </View>

            <Text style={styles.footerWhisper}>
              This iPhone syncs automatically.
            </Text>
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
    return '#8A5C14';
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
  wordmark: {
    ...typography.wordmark,
    color: colors.label,
    paddingTop: spacing.md,
  },
  hero: {
    alignItems: 'center',
    paddingTop: spacing.xxl + spacing.md,
    paddingBottom: spacing.xxl,
    gap: spacing.lg,
  },
  stateWord: {
    ...typography.hero,
    marginTop: spacing.sm,
  },
  substance: {
    ...typography.subhead,
    fontSize: 14,
    color: colors.labelSecondary,
    fontVariant: ['tabular-nums'],
    textAlign: 'center',
  },
  cta: {
    backgroundColor: colors.info,
    borderRadius: radius.md + 2,
    alignItems: 'center',
    paddingVertical: spacing.lg,
    marginBottom: spacing.xl,
  },
  ctaText: {
    ...typography.body,
    fontSize: 16,
    color: colors.background,
  },
  rows: {
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: colors.separator,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    paddingVertical: spacing.lg,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colors.separator,
  },
  dot: {
    width: 7,
    height: 7,
    borderRadius: 4,
  },
  rowLabel: {
    ...typography.body,
    color: colors.label,
  },
  rowValue: {
    ...typography.subhead,
    fontSize: 14,
    color: colors.labelSecondary,
    marginLeft: 'auto',
    maxWidth: 170,
    fontVariant: ['tabular-nums'],
  },
  chevron: {
    ...typography.body,
    color: colors.neutral,
  },
  footerWhisper: {
    ...typography.caption,
    fontWeight: '400',
    color: colors.neutral,
    textAlign: 'center',
    marginTop: 'auto',
    paddingTop: spacing.xxl,
  },
  pressedDim: {
    opacity: 0.6,
  },

  // Welcome
  welcome: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: spacing.xl,
    paddingBottom: spacing.xxl * 2,
  },
  welcomeWordmark: {
    ...typography.wordmarkLarge,
    color: colors.label,
    marginTop: spacing.xl,
  },
  welcomeTagline: {
    ...typography.subhead,
    fontSize: 15,
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
    backgroundColor: '#0B0B0B',
    borderRadius: radius.md + 2,
    paddingVertical: spacing.lg,
    marginTop: spacing.xl,
  },
  appleButtonText: {
    ...typography.body,
    fontSize: 16,
    color: '#FFFFFF',
  },
  welcomeLegal: {
    ...typography.caption,
    fontWeight: '400',
    color: colors.neutral,
    marginTop: spacing.md,
  },
});
