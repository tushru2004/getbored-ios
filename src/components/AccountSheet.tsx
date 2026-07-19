import React from 'react';
import {
  Alert,
  Modal,
  Pressable,
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

/**
 * "Connected · iOS 18.7.9" — the OS version is human-relevant; the raw
 * hardware identifier ("iPhone11,8") is diagnostic detail that stays in
 * the admin, so it's stripped out of the free-text model field here.
 */
function deviceLine(registration: DeviceRegistrationState): string {
  if (registration.kind === 'registered') {
    const model = registration.registration.model;
    const iosPart = model?.split(' · ').find(part => part.startsWith('iOS'));
    if (iosPart) {
      return `Connected · ${iosPart}`;
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
 * The account HALF-sheet: a bottom-anchored panel sized to its content over
 * a dimmed home screen (RN's stock pageSheet can't do detents, so this is a
 * transparent Modal + backdrop + panel). Facts first (full email — this is
 * the one place the raw relay address belongs — and device status), then a
 * visibly separate actions group: Sign Out in the accent, Delete Account in
 * red per App Review 5.1.1(v).
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
    transparent
    animationType="fade"
    onRequestClose={onClose}>
    <View style={styles.backdropFill}>
      <Pressable style={StyleSheet.absoluteFill} onPress={onClose} />
      <View style={styles.panel}>
        <View style={styles.grabber} />
        <Text style={styles.title}>Account</Text>
        <Text style={styles.subtitle}>Signed in with Apple</Text>

        <View style={styles.factRows}>
          <View style={styles.row}>
            <Text style={styles.rowLabel}>Email</Text>
            <Text style={styles.rowValue} numberOfLines={1}>
              {email ?? '—'}
            </Text>
          </View>
          <View style={[styles.row, styles.lastRow]}>
            <Text style={styles.rowLabel}>This iPhone</Text>
            <Text style={styles.rowValue} numberOfLines={1}>
              {deviceLine(registration)}
            </Text>
          </View>
        </View>

        <View style={styles.actionRows}>
          <Pressable
            style={({pressed}) => [styles.row, pressed && styles.pressed]}
            onPress={() => {
              onClose();
              onSignOut();
            }}>
            <Text style={styles.signOutLabel}>Sign Out</Text>
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
      </View>
    </View>
  </Modal>
);

const styles = StyleSheet.create({
  backdropFill: {
    flex: 1,
    justifyContent: 'flex-end',
    backgroundColor: 'rgba(19, 26, 21, 0.42)',
  },
  panel: {
    backgroundColor: colors.surface,
    borderTopLeftRadius: 22,
    borderTopRightRadius: 22,
    paddingHorizontal: spacing.xl,
    paddingTop: spacing.sm,
    paddingBottom: spacing.xxl + spacing.md,
  },
  grabber: {
    alignSelf: 'center',
    width: 36,
    height: 5,
    borderRadius: 3,
    backgroundColor: '#D8D4C7',
    marginBottom: spacing.lg,
  },
  title: {
    fontSize: 20,
    fontWeight: '800',
    letterSpacing: -0.3,
    color: colors.label,
  },
  subtitle: {
    ...typography.subhead,
    color: colors.labelSecondary,
    marginTop: 2,
    marginBottom: spacing.md,
  },
  factRows: {
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: colors.separator,
  },
  actionRows: {
    marginTop: spacing.lg,
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
  rowLabel: {
    fontSize: 16,
    fontWeight: '500',
    color: colors.label,
  },
  rowValue: {
    fontSize: 15,
    fontWeight: '400',
    color: '#556058',
    flexShrink: 1,
    fontVariant: ['tabular-nums'],
  },
  signOutLabel: {
    fontSize: 16,
    fontWeight: '500',
    color: colors.info,
  },
  deleteLabel: {
    fontSize: 16,
    fontWeight: '500',
    color: colors.danger,
  },
});
