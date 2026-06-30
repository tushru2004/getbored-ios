import React, {useState} from 'react';
import {Pressable, StyleSheet, Text, View} from 'react-native';

import {useFilterListSync} from '../../hooks/useFilterListSync';
import {ActiveRulesScreen} from '../../screens/ActiveRulesScreen';
import {colors, radius, spacing, typography, withAlpha} from '../../theme';

/**
 * Card that triggers an iCloud filter-list refresh and links to the read-only
 * rules modal. Two independent pieces of state drive the render:
 *
 *   useFilterListSync().state  ← sync lifecycle
 *       │
 *       ├── 'syncing' → button disabled + "Refreshing...", pressed style forced
 *       ├── 'success' → "Synced" pill in header
 *       ├── 'error'   → error message line under header
 *       └── 'idle'    → plain "Refresh Settings" button
 *
 *   showRules (local)          ← modal visibility
 *       │
 *       ├── "View Active Rules" press → setShowRules(true)
 *       └── ActiveRulesScreen.onClose → setShowRules(false)
 *
 * ActiveRulesScreen is always mounted; its own `visible` prop gates rendering
 * and re-fetches active rules each time showRules flips true.
 */
export const FilterListSyncCard: React.FC = () => {
  const {state, sync} = useFilterListSync();
  const isSyncing = state.kind === 'syncing';
  const [showRules, setShowRules] = useState(false);

  const buttonLabel = isSyncing ? 'Refreshing...' : 'Refresh Settings';

  return (
    <View style={styles.card}>
      <View style={styles.headerRow}>
        <View style={styles.titleColumn}>
          <Text style={styles.title}>Filter Settings</Text>
          <Text style={styles.subtitle}>
            Pull the latest filter lists assigned to this device from iCloud.
          </Text>
        </View>
        {state.kind === 'success' && (
          <View style={styles.successPill}>
            <Text style={styles.successText}>Synced</Text>
          </View>
        )}
      </View>

      {state.kind === 'error' && (
        <Text style={styles.errorText}>{state.message}</Text>
      )}

      <Pressable
        disabled={isSyncing}
        onPress={sync}
        style={({pressed}) => {
          const showPressedStyle = pressed || isSyncing;
          return [styles.button, showPressedStyle && styles.buttonPressed];
        }}>
        <Text style={styles.buttonText}>{buttonLabel}</Text>
      </Pressable>

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
