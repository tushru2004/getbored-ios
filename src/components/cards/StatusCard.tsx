import React from 'react';
import {StyleSheet, Text, View} from 'react-native';

import {FilterStatus, ICloudStatus, StatusViewModel} from '../../native/types';
import {colors, radius, spacing, typography, withAlpha} from '../../theme';

type Props = {
  status: StatusViewModel;
};

type RowVisual = {
  symbol: string;
  tint: string;
  pill?: {text: string; bg: string; fg: string};
};

const filterVisual = (filter: FilterStatus): RowVisual => {
  switch (filter.kind) {
    case 'active':
      return {
        symbol: '✓',
        tint: colors.success,
        pill: {
          text: 'ON',
          bg: withAlpha(colors.success, 0.12),
          fg: colors.success,
        },
      };
    case 'inactive':
      return {
        symbol: '⊘',
        tint: colors.warning,
        pill: {
          text: 'OFF',
          bg: withAlpha(colors.warning, 0.12),
          fg: colors.warning,
        },
      };
    case 'error':
      return {
        symbol: '!',
        tint: colors.danger,
        pill: {
          text: 'ERR',
          bg: withAlpha(colors.danger, 0.12),
          fg: colors.danger,
        },
      };
    case 'checking':
      return {symbol: '…', tint: colors.neutral};
  }
};

const icloudVisual = (icloud: ICloudStatus): RowVisual => {
  switch (icloud.kind) {
    case 'available':
      return {symbol: '☁', tint: colors.info};
    case 'unavailable':
      return {symbol: '☁', tint: colors.danger};
    case 'checking':
      return {symbol: '…', tint: colors.neutral};
  }
};

type RowProps = {
  title: string;
  subtitle: string;
  visual: RowVisual;
};

const Row: React.FC<RowProps> = ({title, subtitle, visual}) => (
  <View style={styles.row}>
    <View
      style={[styles.iconTile, {backgroundColor: withAlpha(visual.tint, 0.13)}]}>
      <Text style={[styles.iconGlyph, {color: visual.tint}]}>
        {visual.symbol}
      </Text>
    </View>
    <View style={styles.textCol}>
      <Text style={styles.title}>{title}</Text>
      <Text style={[styles.subtitle, {color: visual.tint}]}>{subtitle}</Text>
    </View>
    {visual.pill && (
      <View style={[styles.pill, {backgroundColor: visual.pill.bg}]}>
        <Text style={[styles.pillText, {color: visual.pill.fg}]}>
          {visual.pill.text}
        </Text>
      </View>
    )}
  </View>
);

/**
 * Informational block shown when the filter is `inactive`. It exists so a
 * fresh install doesn't dead-end on a bare "OFF" chip with no explanation —
 * there is deliberately no button/link here: turning the filter on happens
 * through the one-time device setup flow, not from this screen.
 */
const SetupRequiredNotice: React.FC = () => (
  <View style={styles.noticeContainer}>
    <Text style={styles.noticeTitle}>Setup required</Text>
    <Text style={styles.noticeBody}>
      The GetBored filter isn't switched on for this device yet. It activates
      through a one-time device setup. Once it's on, this screen will show
      'Active & Protecting.'
    </Text>
  </View>
);

export const StatusCard: React.FC<Props> = ({status}) => {
  const filterRowVisual = filterVisual(status.filter);
  const icloudRowVisual = icloudVisual(status.icloud);
  const isFilterInactive = status.filter.kind === 'inactive';
  return (
    <View style={styles.card}>
      <Row
        title="Content Filter"
        subtitle={status.filter.label}
        visual={filterRowVisual}
      />
      {isFilterInactive && <SetupRequiredNotice />}
      <View style={styles.divider} />
      <Row
        title="iCloud Sync"
        subtitle={status.icloud.label}
        visual={icloudRowVisual}
      />
    </View>
  );
};

const styles = StyleSheet.create({
  card: {
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    paddingVertical: spacing.sm,
    marginHorizontal: spacing.lg,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: spacing.md - 2,
    paddingHorizontal: spacing.md + 2,
  },
  iconTile: {
    width: 36,
    height: 36,
    borderRadius: radius.sm,
    alignItems: 'center',
    justifyContent: 'center',
  },
  iconGlyph: {
    fontSize: 20,
    fontWeight: '700',
  },
  textCol: {
    flex: 1,
    marginLeft: spacing.md,
  },
  title: {
    ...typography.body,
    color: colors.label,
  },
  subtitle: {
    ...typography.subhead,
    marginTop: 2,
  },
  pill: {
    paddingHorizontal: spacing.md - 2,
    paddingVertical: spacing.xs,
    borderRadius: radius.pill,
  },
  pillText: {
    ...typography.caption,
  },
  divider: {
    height: StyleSheet.hairlineWidth,
    backgroundColor: colors.separator,
    marginLeft: 62,
  },
  noticeContainer: {
    marginHorizontal: spacing.md + 2,
    marginBottom: spacing.sm,
    padding: spacing.md,
    borderRadius: radius.sm,
    backgroundColor: withAlpha(colors.warning, 0.08),
  },
  noticeTitle: {
    ...typography.body,
    color: colors.label,
  },
  noticeBody: {
    ...typography.subhead,
    color: colors.labelSecondary,
    marginTop: spacing.xs,
  },
});
