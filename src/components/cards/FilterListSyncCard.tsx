import React, {useState} from 'react';
import {Pressable, StyleSheet, Text, View} from 'react-native';

import {FilterListSyncState} from '../../hooks/useFilterListSync';
import {SyncSummary} from '../../native/types';
import {ActiveRulesScreen} from '../../screens/ActiveRulesScreen';
import {colors, radius, spacing, typography, withAlpha} from '../../theme';

function buttonLabel(state: FilterListSyncState): string {
  if (state.kind === 'syncing') return 'Syncing...';
  return 'Sync Now';
}

function countLabel(count: number, singular: string, plural: string): string {
  if (count === 1) {
    return `1 ${singular}`;
  }
  return `${count} ${plural}`;
}

/**
 * One quiet line of substance under the Synced pill, e.g.
 * "12 sites blocked · 2 apps blocked · synced 4:32 PM". Sites always show
 * (including "0 sites blocked" — an admin clearing every list is real news);
 * apps only when present.
 */
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

type Props = {
  state: FilterListSyncState;
  onSync: () => void;
};

/**
 * Card showing the rule-sync lifecycle and linking to the read-only rules
 * modal. Presentational: syncing runs automatically (after connect, and on
 * every app foreground — see useConnectedApp); the button is a manual
 * "pull right now" for impatient moments and error retries.
 *
 *   state (from useConnectedApp)
 *       │
 *       ├── 'syncing'              → button disabled + "Syncing...", pressed style forced
 *       ├── 'success'              → "Synced" pill in header
 *       ├── 'signedOut'            → notice line, sync button hidden (rules were kept)
 *       ├── 'subscriptionRequired' → notice line, sync button hidden (filtering stopped)
 *       ├── 'notRegistered'        → notice line, button kept (retry after connecting)
 *       ├── 'error'                → error message line under header
 *       └── 'idle'                 → plain "Sync Now" button
 *
 *   showRules (local)          ← modal visibility
 *       │
 *       ├── "View Active Rules" press → setShowRules(true)
 *       └── ActiveRulesScreen.onClose → setShowRules(false)
 *
 * ActiveRulesScreen is always mounted regardless of sync state — the rules
 * it reads are the last ones applied on-device, which stay valid through
 * signedOut/subscriptionRequired, so viewing them is never blocked.
 */
export const FilterListSyncCard: React.FC<Props> = ({state, onSync}) => {
  const isSyncing = state.kind === 'syncing';
  // notRegistered keeps the button: the fix (connecting, in the card above)
  // doesn't reset this card's state, so hiding the button here would leave no
  // way to retry after connecting. signedOut/subscriptionRequired still hide
  // it — their fixes (signing in / reactivating) re-render the whole screen.
  const isBlocked =
    state.kind === 'signedOut' || state.kind === 'subscriptionRequired';
  const [showRules, setShowRules] = useState(false);

  return (
    <View style={styles.card}>
      <View style={styles.headerRow}>
        <View style={styles.titleColumn}>
          <Text style={styles.title}>Filter Settings</Text>
          <Text style={styles.subtitle}>
            Pull your latest self-control rules from your account.
          </Text>
        </View>
        {state.kind === 'success' && (
          <View style={styles.successPill}>
            <Text style={styles.successText}>Synced</Text>
          </View>
        )}
      </View>

      {state.kind === 'success' && (
        <Text style={styles.noticeText}>
          {summaryLine(state.summary, state.syncedAtMs)}
        </Text>
      )}
      {state.kind === 'error' && (
        <Text style={styles.errorText}>{state.message}</Text>
      )}
      {state.kind === 'signedOut' && (
        <Text style={styles.noticeText}>
          Sign in again to refresh your settings.
        </Text>
      )}
      {state.kind === 'subscriptionRequired' && (
        <Text style={styles.noticeText}>
          Filtering has stopped until your subscription is active again.
        </Text>
      )}
      {state.kind === 'notRegistered' && (
        <Text style={styles.noticeText}>
          Connect this device above before syncing.
        </Text>
      )}

      {!isBlocked && (
        <Pressable
          disabled={isSyncing}
          onPress={onSync}
          style={({pressed}) => {
            const showPressedStyle = pressed || isSyncing;
            return [styles.button, showPressedStyle && styles.buttonPressed];
          }}>
          <Text style={styles.buttonText}>{buttonLabel(state)}</Text>
        </Pressable>
      )}

      <Pressable
        onPress={() => setShowRules(true)}
        style={({pressed}) => [styles.viewRulesRow, pressed && styles.buttonPressed]}>
        <Text style={styles.viewRulesText}>View Active Rules</Text>
        <Text style={styles.viewRulesChevron}>›</Text>
      </Pressable>

      <ActiveRulesScreen
        visible={showRules}
        onClose={() => setShowRules(false)}
      />
    </View>
  );
};

const styles = StyleSheet.create({
  card: {
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    marginHorizontal: spacing.lg,
    marginTop: spacing.lg,
    padding: spacing.md,
  },
  headerRow: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    justifyContent: 'space-between',
    gap: spacing.md,
  },
  titleColumn: {
    flex: 1,
  },
  title: {
    ...typography.headline,
    color: colors.label,
  },
  subtitle: {
    ...typography.subhead,
    color: colors.labelSecondary,
    marginTop: spacing.xs,
  },
  successPill: {
    borderRadius: radius.pill,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.xs,
    backgroundColor: withAlpha(colors.success, 0.12),
  },
  successText: {
    ...typography.caption,
    color: colors.success,
  },
  errorText: {
    ...typography.subhead,
    color: colors.danger,
    marginTop: spacing.md,
  },
  noticeText: {
    ...typography.subhead,
    color: colors.labelSecondary,
    marginTop: spacing.md,
  },
  button: {
    alignItems: 'center',
    backgroundColor: colors.info,
    borderRadius: radius.sm,
    marginTop: spacing.md,
    paddingVertical: spacing.md,
  },
  buttonPressed: {
    opacity: 0.7,
  },
  buttonText: {
    ...typography.body,
    color: '#FFFFFF',
  },
  viewRulesRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginTop: spacing.sm,
    paddingVertical: spacing.sm,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: colors.separator,
  },
  viewRulesText: {
    ...typography.subhead,
    color: colors.info,
  },
  viewRulesChevron: {
    ...typography.body,
    color: colors.labelSecondary,
  },
});
