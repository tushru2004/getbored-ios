import React from 'react';
import {Pressable, StyleSheet, Text, View} from 'react-native';

import {useFilterListSync} from '../../hooks/useFilterListSync';
import {colors, radius, spacing, typography, withAlpha} from '../../theme';

export const FilterListSyncCard: React.FC = () => {
  const {state, sync} = useFilterListSync();
  const isSyncing = state.kind === 'syncing';

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
        style={({pressed}) => [
          styles.button,
          (pressed || isSyncing) && styles.buttonPressed,
        ]}>
        <Text style={styles.buttonText}>
          {isSyncing ? 'Refreshing...' : 'Refresh Settings'}
        </Text>
      </Pressable>
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
});
