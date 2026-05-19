import React, {useEffect, useState} from 'react';
import {SafeAreaView, ScrollView, Text, StyleSheet, NativeModules, PlatformColor} from 'react-native';
import {StatusCard, FilterStatusVM} from './components/StatusCard';

const {FilterStatus} = NativeModules as {
  FilterStatus?: {current: () => Promise<FilterStatusVM>};
};

export default function App() {
  const [status, setStatus] = useState<FilterStatusVM | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    const load = async () => {
      if (!FilterStatus) {
        setError('FilterStatus native module not linked');
        return;
      }
      try {
        const vm = await FilterStatus.current();
        if (!cancelled) setStatus(vm);
      } catch (e: any) {
        if (!cancelled) setError(e?.message ?? String(e));
      }
    };
    load();
    const id = setInterval(load, 5000);
    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, []);

  return (
    <SafeAreaView style={styles.root}>
      <ScrollView contentContainerStyle={styles.scroll}>
        <Text style={styles.header}>GetBored</Text>
        <StatusCard status={status} />
        {error && <Text style={styles.error}>{error}</Text>}
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  root: {
    flex: 1,
    backgroundColor: PlatformColor('systemGroupedBackground'),
  },
  scroll: {
    paddingVertical: 16,
  },
  header: {
    fontSize: 28,
    fontWeight: '700',
    marginHorizontal: 16,
    marginBottom: 12,
    color: PlatformColor('label'),
  },
  error: {
    marginHorizontal: 16,
    marginTop: 12,
    color: '#FF3B30',
    fontSize: 13,
  },
});
