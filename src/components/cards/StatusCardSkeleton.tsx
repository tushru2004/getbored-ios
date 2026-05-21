import React, {useEffect, useRef} from 'react';
import {Animated, StyleSheet, View} from 'react-native';

import {colors, radius, spacing} from '../../theme';

const useShimmer = () => {
  const opacity = useRef(new Animated.Value(0.4)).current;

  useEffect(() => {
    const loop = Animated.loop(
      Animated.sequence([
        Animated.timing(opacity, {
          toValue: 0.8,
          duration: 800,
          useNativeDriver: true,
        }),
        Animated.timing(opacity, {
          toValue: 0.4,
          duration: 800,
          useNativeDriver: true,
        }),
      ]),
    );
    loop.start();
    return () => loop.stop();
  }, [opacity]);

  return opacity;
};

const SkeletonRow: React.FC<{opacity: Animated.Value}> = ({opacity}) => (
  <View style={styles.row}>
    <Animated.View style={[styles.iconTile, {opacity}]} />
    <View style={styles.textCol}>
      <Animated.View style={[styles.lineWide, {opacity}]} />
      <Animated.View style={[styles.lineNarrow, {opacity}]} />
    </View>
  </View>
);

export const StatusCardSkeleton: React.FC = () => {
  const opacity = useShimmer();
  return (
    <View style={styles.card}>
      <SkeletonRow opacity={opacity} />
      <View style={styles.divider} />
      <SkeletonRow opacity={opacity} />
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
    backgroundColor: colors.separator,
  },
  textCol: {
    flex: 1,
    marginLeft: spacing.md,
  },
  lineWide: {
    height: 14,
    width: '60%',
    borderRadius: 4,
    backgroundColor: colors.separator,
  },
  lineNarrow: {
    height: 10,
    width: '40%',
    borderRadius: 4,
    backgroundColor: colors.separator,
    marginTop: 6,
  },
  divider: {
    height: StyleSheet.hairlineWidth,
    backgroundColor: colors.separator,
    marginLeft: 62,
  },
});
