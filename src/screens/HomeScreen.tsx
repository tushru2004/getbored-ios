import React from 'react';
import {SafeAreaView, ScrollView, StyleSheet, Text, View} from 'react-native';

import {ErrorBoundary} from '../components/ErrorBoundary';
import {DeviceRegistrationCard} from '../components/cards/DeviceRegistrationCard';
import {FilterListSyncCard} from '../components/cards/FilterListSyncCard';
import {SignInCard} from '../components/cards/SignInCard';
import {StatusCard} from '../components/cards/StatusCard';
import {StatusCardSkeleton} from '../components/cards/StatusCardSkeleton';
import {AccountState} from '../hooks/useAccount';
import {useConnectedApp} from '../hooks/useConnectedApp';
import {useFilterStatus} from '../hooks/useFilterStatus';
import {colors, spacing, typography} from '../theme';

/**
 * Picks the right card for the current filter-status fetch state.
 *
 *   useFilterStatus().state.kind
 *       │
 *       ├── 'loading' → <StatusCardSkeleton />
 *       ├── 'ready'   → <StatusCard status={state.status} />
 *       └── 'error'   → error box with "Tap to retry" → refresh()
 */
const StatusSection: React.FC = () => {
  const {state, refresh} = useFilterStatus();

  switch (state.kind) {
    case 'loading':
      return <StatusCardSkeleton />;
    case 'ready':
      return <StatusCard status={state.status} />;
    case 'error':
      return (
        <View style={styles.errorBox}>
          <Text style={styles.errorTitle}>Couldn’t load status</Text>
          <Text style={styles.errorMessage}>{state.message}</Text>
          <Text style={styles.errorRetry} onPress={refresh}>
            Tap to retry
          </Text>
        </View>
      );
  }
};

/**
 * The register-device and sync cards need a signed-in server session, so
 * they're gated on account state: shown once signed in, and also shown on
 * a native build that predates the Account module (`unavailable`) since
 * there's no signal to gate on there — that's the pre-migration app, and
 * pre-migration those cards were always visible.
 */
function areGatedCardsUnlocked(accountState: AccountState): boolean {
  return accountState.kind === 'signedIn' || accountState.kind === 'unavailable';
}

export const HomeScreen: React.FC = () => {
  const {account, registration, filterSync} = useConnectedApp();

  return (
    <SafeAreaView style={styles.root}>
      <ScrollView contentContainerStyle={styles.scroll}>
        <Text style={styles.header}>GetBored</Text>
        <ErrorBoundary>
          <StatusSection />
          <SignInCard
            account={account.state}
            onSignIn={account.signIn}
            onSignOut={account.signOut}
            onDeleteAccount={account.deleteAccount}
          />
          {areGatedCardsUnlocked(account.state) && (
            <>
              <DeviceRegistrationCard
                state={registration.state}
                onConnect={registration.register}
              />
              <FilterListSyncCard
                state={filterSync.state}
                onSync={filterSync.sync}
              />
            </>
          )}
        </ErrorBoundary>
      </ScrollView>
    </SafeAreaView>
  );
};

const styles = StyleSheet.create({
  root: {
    flex: 1,
    backgroundColor: colors.background,
  },
  scroll: {
    paddingVertical: spacing.lg,
  },
  header: {
    ...typography.title,
    color: colors.label,
    marginHorizontal: spacing.lg,
    marginBottom: spacing.md,
  },
  errorBox: {
    marginHorizontal: spacing.lg,
    padding: spacing.lg,
    backgroundColor: colors.surface,
    borderRadius: 12,
  },
  errorTitle: {
    ...typography.headline,
    color: colors.label,
    marginBottom: spacing.xs,
  },
  errorMessage: {
    ...typography.subhead,
    color: colors.labelSecondary,
    marginBottom: spacing.md,
  },
  errorRetry: {
    ...typography.body,
    color: colors.info,
  },
});
