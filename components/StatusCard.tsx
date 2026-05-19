import React from 'react';
import {View, Text, StyleSheet, PlatformColor} from 'react-native';

export type FilterStatusVM = {
  filterState: 'active' | 'inactive' | 'checking' | 'error';
  filterLabel: string;
  icloudState: 'available' | 'unavailable' | 'checking';
  icloudLabel: string;
};

type Props = {
  status: FilterStatusVM | null;
};

const filterVisual = (state: FilterStatusVM['filterState']) => {
  switch (state) {
    case 'active':
      return {symbol: '✓', tint: '#34C759', pill: 'ON', pillBg: 'rgba(52,199,89,0.12)', pillFg: '#34C759'};
    case 'inactive':
      return {symbol: '⊘', tint: '#FF9500', pill: 'OFF', pillBg: 'rgba(255,149,0,0.12)', pillFg: '#FF9500'};
    case 'error':
      return {symbol: '!', tint: '#FF3B30', pill: 'ERR', pillBg: 'rgba(255,59,48,0.12)', pillFg: '#FF3B30'};
    case 'checking':
    default:
      return {symbol: '…', tint: '#8E8E93', pill: '…', pillBg: 'rgba(142,142,147,0.12)', pillFg: '#8E8E93'};
  }
};

const icloudVisual = (state: FilterStatusVM['icloudState']) => {
  switch (state) {
    case 'available':
      return {symbol: '☁', tint: '#007AFF'};
    case 'unavailable':
      return {symbol: '☁', tint: '#FF3B30'};
    case 'checking':
    default:
      return {symbol: '…', tint: '#8E8E93'};
  }
};

export const StatusCard: React.FC<Props> = ({status}) => {
  const filterState = status?.filterState ?? 'checking';
  const filterLabel = status?.filterLabel ?? 'Checking...';
  const icloudState = status?.icloudState ?? 'checking';
  const icloudLabel = status?.icloudLabel ?? 'Checking...';

  const fv = filterVisual(filterState);
  const iv = icloudVisual(icloudState);

  return (
    <View style={styles.card}>
      <View style={styles.row}>
        <View style={[styles.iconTile, {backgroundColor: fv.tint + '22'}]}>
          <Text style={[styles.iconGlyph, {color: fv.tint}]}>{fv.symbol}</Text>
        </View>
        <View style={styles.textCol}>
          <Text style={styles.title}>Content Filter</Text>
          <Text style={[styles.subtitle, {color: fv.tint}]}>{filterLabel}</Text>
        </View>
        <View style={[styles.pill, {backgroundColor: fv.pillBg}]}>
          <Text style={[styles.pillText, {color: fv.pillFg}]}>{fv.pill}</Text>
        </View>
      </View>

      <View style={styles.divider} />

      <View style={styles.row}>
        <View style={[styles.iconTile, {backgroundColor: iv.tint + '22'}]}>
          <Text style={[styles.iconGlyph, {color: iv.tint}]}>{iv.symbol}</Text>
        </View>
        <View style={styles.textCol}>
          <Text style={styles.title}>iCloud Sync</Text>
          <Text style={[styles.subtitle, {color: iv.tint}]}>{icloudLabel}</Text>
        </View>
      </View>
    </View>
  );
};

const styles = StyleSheet.create({
  card: {
    backgroundColor: PlatformColor('secondarySystemGroupedBackground'),
    borderRadius: 12,
    paddingVertical: 8,
    marginHorizontal: 16,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: 10,
    paddingHorizontal: 14,
  },
  iconTile: {
    width: 36,
    height: 36,
    borderRadius: 8,
    alignItems: 'center',
    justifyContent: 'center',
  },
  iconGlyph: {
    fontSize: 20,
    fontWeight: '700',
  },
  textCol: {
    flex: 1,
    marginLeft: 12,
  },
  title: {
    fontSize: 15,
    fontWeight: '600',
    color: PlatformColor('label'),
  },
  subtitle: {
    fontSize: 13,
    marginTop: 2,
  },
  pill: {
    paddingHorizontal: 10,
    paddingVertical: 4,
    borderRadius: 999,
  },
  pillText: {
    fontSize: 12,
    fontWeight: '700',
  },
  divider: {
    height: StyleSheet.hairlineWidth,
    backgroundColor: PlatformColor('separator'),
    marginLeft: 62,
  },
});
