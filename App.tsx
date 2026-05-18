import React from 'react';
import {View, Text, StyleSheet, SafeAreaView} from 'react-native';

export default function App() {
  return (
    <SafeAreaView style={styles.container}>
      <View style={styles.center}>
        <Text style={styles.title}>GetBored iOS</Text>
      </View>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {flex: 1, backgroundColor: '#fff'},
  center: {flex: 1, alignItems: 'center', justifyContent: 'center'},
  title: {fontSize: 24, fontWeight: '600'},
});
