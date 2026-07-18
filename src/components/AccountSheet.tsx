import React from 'react';
import {
  Alert,
  Modal,
  Pressable,
  SafeAreaView,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import {DeviceRegistrationState} from '../hooks/useDeviceRegistration';
import {colors, spacing, typography} from '../theme';

type Props = {
  visible: boolean;
  onClose: () => void;
  email?: string;
  registration: DeviceRegistrationState;
  onSignOut: () => void;
  onDeleteAccount: () => void;
};

function deviceLine(registration: DeviceRegistrationState): string {
  if (registration.kind === 'registered') {
    const model = registration.registration.model;
    if (model) {
      return `Connected · ${model}`;
    }
    return 'Connected';
  }
  if (registration.kind === 'saving' || registration.kind === 'checking') {
    return 'Connecting…';
  }
  return 'Not connected';
}

/**
 * Native confirmation ahead of the irreversible path. Deletion itself runs
 * in useAccount → native deleteAccount; this only guards the tap.
 */
function confirmDeleteAccount(onConfirmed: () => void) {
  Alert.alert(
    'Delete account?',
    'This permanently deletes your account, connected devices, and blocklists. Filtering on this device will stop.',
    [
      {text: 'Cancel', style: 'cancel'},
      {text: 'Delete', style: 'destructive', onPress: onConfirmed},
    ],
  );
}

/**
 * The account pageSheet, one level below the home screen: identity, device
 * status, Sign Out, and the App Review 5.1.1(v) Delete Account flow. On the
 * home screen these were noise; in a sheet they're where you'd look.
 */
export const AccountSheet: React.FC<Props> = ({
  visible,
  onClose,
  email,
  registration,
  onSignOut,
  onDeleteAccount,
}) => (
  <Modal
    visible={visible}
    animationType="slide"
    presentationStyle="pageSheet"
    onRequestClose={onClose}>
    <SafeAreaView style={styles.root}>
      <View style={styles.header}>
        <View>
          <Text style={styles.title}>Account</Text>
          <Text style={styles.subtitle}>Signed in with Apple</Text>
        </View>
        <Pressable onPress={onClose} hitSlop={12}>
          <Text style={styles.done}>Done</Text>
        </Pressable>
      </View>

      <View style={styles.rows}>
        <View style={styles.row}>
          <Text style={styles.label}>Email</Text>
          <Text style={styles.value} numberOfLines={1}>
            {email ?? '—'}
          </Text>
        </View>
        <View style={styles.row}>
          <Text style={styles.label}>This iPhone</Text>
          <Text style={styles.value} numberOfLines={1}>
            {deviceLine(registration)}
          </Text>
        </View>
        <Pressable
          style={({pressed}) => [styles.row, pressed && styles.pressed]}
          onPress={() => {
            onClose();
            onSignOut();
          }}>
          <Text style={styles.label}>Sign Out</Text>
        </Pressable>
        <Pressable
          style={({pressed}) => [
            styles.row,
            styles.lastRow,
            pressed && styles.pressed,
          ]}
          onPress={() =>
            confirmDeleteAccount(() => {
              onClose();
              onDeleteAccount();
            })
          }>
          <Text style={styles.deleteLabel}>Delete Account…</Text>
        </Pressable>
      </View>
    </SafeAreaView>
  </Modal>
);

const styles = StyleSheet.create({
  root: {
    flex: 1,
    backgroundColor: colors.surface,
  },
  header: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    justifyContent: 'space-between',
    paddingHorizontal: spacing.xl,
    paddingTop: spacing.xl,
    paddingBottom: spacing.lg,
  },
  title: {
    ...typography.title,
    color: colors.label,
  },
  subtitle: {
    ...typography.subhead,
    color: colors.labelSecondary,
    marginTop: spacing.xs,
  },
  done: {
    ...typography.body,
    color: colors.info,
    paddingTop: spacing.sm,
  },
  rows: {
    marginHorizontal: spacing.xl,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: colors.separator,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: spacing.md,
    paddingVertical: spacing.lg,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colors.separator,
  },
  lastRow: {
    borderBottomWidth: 0,
  },
  pressed: {
    opacity: 0.6,
  },
  label: {
    ...typography.body,
    color: colors.label,
  },
  deleteLabel: {
    ...typography.body,
    color: colors.danger,
  },
  value: {
    ...typography.subhead,
    color: colors.labelSecondary,
    flexShrink: 1,
  },
});
