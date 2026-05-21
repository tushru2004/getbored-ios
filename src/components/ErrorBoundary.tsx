import React, {Component, ErrorInfo, ReactNode} from 'react';
import {Pressable, StyleSheet, Text, View} from 'react-native';

import {colors, radius, spacing, typography} from '../theme';

type Props = {
  children: ReactNode;
  fallback?: (error: Error, reset: () => void) => ReactNode;
};

type State = {
  error: Error | null;
};

export class ErrorBoundary extends Component<Props, State> {
  state: State = {error: null};

  static getDerivedStateFromError(error: Error): State {
    return {error};
  }

  componentDidCatch(error: Error, info: ErrorInfo): void {
    console.error('[ErrorBoundary]', error, info.componentStack);
  }

  reset = (): void => {
    this.setState({error: null});
  };

  render(): ReactNode {
    const {error} = this.state;
    if (!error) return this.props.children;
    if (this.props.fallback) return this.props.fallback(error, this.reset);
    return <DefaultFallback error={error} onRetry={this.reset} />;
  }
}

type FallbackProps = {error: Error; onRetry: () => void};

export const DefaultFallback: React.FC<FallbackProps> = ({error, onRetry}) => (
  <View style={styles.root}>
    <Text style={styles.title}>Something went wrong</Text>
    <Text style={styles.message}>{error.message}</Text>
    <Pressable
      onPress={onRetry}
      style={({pressed}) => [styles.button, pressed && styles.buttonPressed]}>
      <Text style={styles.buttonText}>Retry</Text>
    </Pressable>
  </View>
);

const styles = StyleSheet.create({
  root: {
    flex: 1,
    backgroundColor: colors.background,
    alignItems: 'center',
    justifyContent: 'center',
    padding: spacing.xl,
  },
  title: {
    ...typography.headline,
    color: colors.label,
    marginBottom: spacing.sm,
  },
  message: {
    ...typography.subhead,
    color: colors.labelSecondary,
    textAlign: 'center',
    marginBottom: spacing.xl,
  },
  button: {
    paddingHorizontal: spacing.xl,
    paddingVertical: spacing.md,
    borderRadius: radius.sm,
    backgroundColor: colors.info,
  },
  buttonPressed: {
    opacity: 0.7,
  },
  buttonText: {
    ...typography.body,
    color: '#FFFFFF',
  },
});
