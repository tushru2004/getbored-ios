import React from 'react';
import {Pressable, StyleSheet, Text, View} from 'react-native';

import {useDeviceRegistration} from '../../hooks/useDeviceRegistration';
import {DeviceRegistration} from '../../native/types';
import {colors, radius, spacing, typography, withAlpha} from '../../theme';

const RegistrationDetails: React.FC<{registration: DeviceRegistration}> = ({
  registration,
}) => (
  <View style={styles.details}>
    <Text style={styles.detailText}>{registration.deviceName}</Text>
    <Text style={styles.metaText}>
      {registration.deviceModel} · iOS {registration.systemVersion}
    </Text>
    <Text style={styles.metaText}>Device ID {registration.id}</Text>
  </View>
);

export const DeviceRegistrationCard: React.FC = () => {
  const {state, register} = useDeviceRegistration();
  const isChecking = state.kind === 'checking';
  const isSaving = state.kind === 'saving';
  const isRegistered = state.kind === 'registered';
  const isBusy = isChecking || isSaving;

  return (
    <View style={styles.card}>
      <View style={styles.headerRow}>
        <View style={styles.titleColumn}>
          <Text style={styles.title}>Device Sync</Text>
          <Text style={styles.subtitle}>
            Sync this device to your GetBored account so your rules follow you everywhere.
          </Text>
        </View>
        <View
          style={[
            styles.statusPill,
            isRegistered ? styles.registeredPill : styles.pendingPill,
          ]}>
          <Text
            style={[
              styles.statusText,
              isRegistered ? styles.registeredText : styles.pendingText,
            ]}>
            {isChecking
              ? 'Checking'
              : isRegistered
                ? 'Registered'
                : 'Not registered'}
          </Text>
        </View>
      </View>

      {state.kind === 'registered' && (
        <RegistrationDetails registration={state.registration} />
      )}
      {state.kind === 'error' && (
        <Text style={styles.errorText}>{state.message}</Text>
      )}

      <Pressable
        disabled={isBusy}
        onPress={register}
        style={({pressed}) => [
          styles.button,
          (pressed || isBusy) && styles.buttonPressed,
        ]}>
        <Text style={styles.buttonText}>
          {isChecking
            ? 'Checking...'
            : isSaving
            ? 'Registering...'
            : isRegistered
              ? 'Refresh Sync'
              : 'Set Up This Device'}
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
  statusPill: {
    borderRadius: radius.pill,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.xs,
  },
  pendingPill: {
    backgroundColor: withAlpha(colors.neutral, 0.12),
  },
  registeredPill: {
    backgroundColor: withAlpha(colors.success, 0.12),
  },
  statusText: {
    ...typography.caption,
  },
  pendingText: {
    color: colors.neutral,
  },
  registeredText: {
    color: colors.success,
  },
  details: {
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: colors.separator,
    marginTop: spacing.md,
    paddingTop: spacing.md,
  },
  detailText: {
    ...typography.body,
    color: colors.label,
  },
  metaText: {
    ...typography.subhead,
    color: colors.labelSecondary,
    marginTop: spacing.xs,
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
