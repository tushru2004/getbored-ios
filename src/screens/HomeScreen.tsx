import React from 'react';
import {SafeAreaView, ScrollView, StyleSheet, Text, View} from 'react-native';

import {ErrorBoundary} from '../components/ErrorBoundary';
import {AppGroupDefaultsCard} from '../components/cards/AppGroupDefaultsCard';
import {StatusCard} from '../components/cards/StatusCard';
import {StatusCardSkeleton} from '../components/cards/StatusCardSkeleton';
import {useFilterStatus} from '../hooks/useFilterStatus';
import {colors, spacing, typography} from '../theme';

const StatusSection: React.FC = () => {
  const {state, refresh} = useFilterStatus();

  switch (state.kind) {
    case 'loading':
      return <StatusCardSkeleton />;
    case 'ready':
      return <StatusCard status={state.status} />;
    case 'error':
      return (
        <View style={styles.errorBox}>
          <Text style={styles.errorTitle}>Couldn’t load status</Text>
          <Text style={styles.errorMessage}>{state.message}</Text>
          <Text style={styles.errorRetry} onPress={refresh}>
            Tap to retry
          </Text>
        </View>
      );
  }
};

export const HomeScreen: React.FC = () => (
  <SafeAreaView style={styles.root}>
    <ScrollView contentContainerStyle={styles.scroll}>
      <Text style={styles.header}>GetBored</Text>
      <ErrorBoundary>
        <StatusSection />
        <AppGroupDefaultsCard />
      </ErrorBoundary>
    </ScrollView>
  </SafeAreaView>
);

const styles = StyleSheet.create({
  root: {
    flex: 1,
    backgroundColor: colors.background,
  },
  scroll: {
    paddingVertical: spacing.lg,
  },
  header: {
    ...typography.title,
    color: colors.label,
    marginHorizontal: spacing.lg,
    marginBottom: spacing.md,
  },
  errorBox: {
    marginHorizontal: spacing.lg,
    padding: spacing.lg,
    backgroundColor: colors.surface,
    borderRadius: 12,
  },
  errorTitle: {
    ...typography.headline,
    color: colors.label,
    marginBottom: spacing.xs,
  },
  errorMessage: {
    ...typography.subhead,
    color: colors.labelSecondary,
    marginBottom: spacing.md,
  },
  errorRetry: {
    ...typography.body,
    color: colors.info,
  },
});
