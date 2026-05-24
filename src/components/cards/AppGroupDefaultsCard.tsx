import React from 'react';
import {Pressable, StyleSheet, Text, View} from 'react-native';

import {useAppGroupDefaults} from '../../hooks/useAppGroupDefaults';
import {AppGroupDefaultsSnapshot} from '../../native/types';
import {colors, radius, spacing, typography} from '../../theme';

const FlowLog: React.FC<{snapshot: AppGroupDefaultsSnapshot}> = ({
  snapshot,
}) => {
  const latest = snapshot.flowLog.slice(-8).reverse();
  return (
    <View style={styles.block}>
      <View style={styles.statRow}>
        <Text style={styles.statLabel}>Flow Log</Text>
        <Text style={styles.statValue}>
          {snapshot.flowLogCount}/{snapshot.flowLogLimit}
        </Text>
      </View>
      <Text style={styles.keyText}>{snapshot.flowLogKey}</Text>
      {latest.length === 0 ? (
        <Text style={styles.emptyText}>No flow events written yet.</Text>
      ) : (
        latest.map((event, index) => (
          <Text key={`${event}-${index}`} style={styles.eventText}>
            {event}
          </Text>
        ))
      )}
    </View>
  );
};

const KeyList: React.FC<{snapshot: AppGroupDefaultsSnapshot}> = ({
  snapshot,
}) => (
  <View style={styles.block}>
    <View style={styles.statRow}>
      <Text style={styles.statLabel}>App Group Keys</Text>
      <Text style={styles.statValue}>{snapshot.keys.length}</Text>
    </View>
    {snapshot.keys.slice(0, 12).map(item => (
      <View key={item.key} style={styles.keyRow}>
        <View style={styles.keyNameColumn}>
          <Text style={styles.keyName}>{item.key}</Text>
          <Text style={styles.keyPreview} numberOfLines={2}>
            {item.preview}
          </Text>
        </View>
        <Text style={styles.keyType}>{item.type}</Text>
      </View>
    ))}
  </View>
);

export const AppGroupDefaultsCard: React.FC = () => {
  const {state, refresh} = useAppGroupDefaults();

  return (
    <View style={styles.card}>
      <View style={styles.headerRow}>
        <View>
          <Text style={styles.title}>App Group UserDefaults</Text>
          <Text style={styles.subtitle}>
            {state.kind === 'ready'
              ? state.snapshot.groupIdentifier
              : 'group.com.getbored.ios'}
          </Text>
        </View>
        <Pressable
          onPress={refresh}
          style={({pressed}) => [
            styles.refreshButton,
            pressed && styles.buttonPressed,
          ]}>
          <Text style={styles.refreshText}>Refresh</Text>
        </Pressable>
      </View>

      {state.kind === 'loading' && (
        <Text style={styles.emptyText}>Loading defaults...</Text>
      )}
      {state.kind === 'error' && (
        <Text style={styles.errorText}>{state.message}</Text>
      )}
      {state.kind === 'ready' && (
        <>
          <FlowLog snapshot={state.snapshot} />
          <KeyList snapshot={state.snapshot} />
        </>
      )}
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
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: spacing.md,
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
  refreshButton: {
    backgroundColor: colors.info,
    borderRadius: radius.sm,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
  },
  buttonPressed: {
    opacity: 0.7,
  },
  refreshText: {
    ...typography.caption,
    color: '#FFFFFF',
  },
  block: {
    marginTop: spacing.lg,
  },
  statRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginBottom: spacing.xs,
  },
  statLabel: {
    ...typography.body,
    color: colors.label,
  },
  statValue: {
    ...typography.caption,
    color: colors.info,
  },
  keyText: {
    ...typography.caption,
    color: colors.labelSecondary,
    marginBottom: spacing.sm,
  },
  emptyText: {
    ...typography.subhead,
    color: colors.labelSecondary,
    marginTop: spacing.sm,
  },
  errorText: {
    ...typography.subhead,
    color: colors.danger,
    marginTop: spacing.md,
  },
  eventText: {
    fontFamily: 'Menlo',
    fontSize: 11,
    color: colors.label,
    backgroundColor: colors.background,
    borderRadius: radius.sm,
    padding: spacing.sm,
    marginTop: spacing.xs,
  },
  keyRow: {
    flexDirection: 'row',
    gap: spacing.md,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: colors.separator,
    paddingVertical: spacing.sm,
  },
  keyNameColumn: {
    flex: 1,
  },
  keyName: {
    ...typography.caption,
    color: colors.label,
  },
  keyPreview: {
    ...typography.subhead,
    color: colors.labelSecondary,
    marginTop: 2,
  },
  keyType: {
    ...typography.caption,
    color: colors.neutral,
  },
});
