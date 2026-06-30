import React, {useEffect, useState} from 'react';
import {
  ActivityIndicator,
  Modal,
  Pressable,
  SafeAreaView,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import {useActiveRules} from '../hooks/useActiveRules';
import {ActiveRules} from '../native/types';
import {colors, radius, spacing, typography, withAlpha} from '../theme';

const INITIAL_VISIBLE = 5;

// ─── Mode badge ────────────────────────────────────────────────────────────

type ModeConfig = {
  label: string;
  description: string;
  badgeColor: string;
};

function getModeConfig(mode: ActiveRules['mode']): ModeConfig {
  if (mode === 'whiteList') {
    return {
      label: 'Allow-only',
      description: 'Only the sites listed below can be reached. Everything else is blocked.',
      badgeColor: colors.success,
    };
  }
  return {
    label: 'Block mode',
    description: 'The sites listed below are blocked. Everything else is allowed.',
    badgeColor: colors.danger,
  };
}

const ModeCard: React.FC<{mode: ActiveRules['mode']}> = ({mode}) => {
  const config = getModeConfig(mode);
  return (
    <View style={styles.modeCard}>
      <View style={styles.modeRow}>
        <Text style={styles.modeLabel}>{config.label}</Text>
        <View style={[styles.modeBadge, {backgroundColor: withAlpha(config.badgeColor, 0.15)}]}>
          <Text style={[styles.modeBadgeText, {color: config.badgeColor}]}>
            {mode === 'whiteList' ? 'ALLOW' : 'BLOCK'}
          </Text>
        </View>
      </View>
      <Text style={styles.modeDescription}>{config.description}</Text>
    </View>
  );
};

// ─── Section ───────────────────────────────────────────────────────────────

type SectionProps = {
  title: string;
  items: string[];
  badge: string;
  badgeColor: string;
  emptyLabel: string;
};

const RulesSection: React.FC<SectionProps> = ({title, items, badge, badgeColor, emptyLabel}) => {
  const [showAll, setShowAll] = useState(false);
  const visible = showAll ? items : items.slice(0, INITIAL_VISIBLE);
  const hiddenCount = items.length - INITIAL_VISIBLE;

  return (
    <View style={styles.section}>
      <View style={styles.sectionHeader}>
        <Text style={styles.sectionTitle}>{title}</Text>
        <Text style={styles.sectionCount}>{items.length}</Text>
      </View>

      <View style={styles.sectionBody}>
        {items.length === 0 ? (
          <Text style={styles.emptyText}>{emptyLabel}</Text>
        ) : (
          <>
            {visible.map(item => (
              <View key={item} style={styles.row}>
                <Text style={styles.rowDomain} numberOfLines={1}>{item}</Text>
                <View style={[styles.rowBadge, {backgroundColor: withAlpha(badgeColor, 0.12)}]}>
                  <Text style={[styles.rowBadgeText, {color: badgeColor}]}>{badge}</Text>
                </View>
              </View>
            ))}
            {!showAll && hiddenCount > 0 && (
              <Pressable onPress={() => setShowAll(true)} style={styles.showMore}>
                <Text style={styles.showMoreText}>Show {hiddenCount} more</Text>
              </Pressable>
            )}
          </>
        )}
      </View>
    </View>
  );
};

// ─── Allowed Apps section ──────────────────────────────────────────────────

const AllowedAppsSection: React.FC<{apps: string[]}> = ({apps}) => (
  <View style={styles.section}>
    <View style={styles.sectionHeader}>
      <Text style={styles.sectionTitle}>ALLOWED APPS</Text>
      <Text style={styles.sectionCount}>{apps.length}</Text>
    </View>
    <View style={styles.sectionBody}>
      {apps.length === 0 ? (
        <Text style={styles.emptyText}>No app overrides configured.</Text>
      ) : (
        apps.map(bundleID => (
          <View key={bundleID} style={styles.row}>
            <Text style={styles.rowDomain} numberOfLines={1}>{bundleID}</Text>
          </View>
        ))
      )}
    </View>
  </View>
);

// ─── Blocked Apps section ──────────────────────────────────────────────────

const BlockedAppsSection: React.FC<{apps: string[]}> = ({apps}) => (
  <View style={styles.section}>
    <View style={styles.sectionHeader}>
      <Text style={styles.sectionTitle}>BLOCKED APPS</Text>
      <Text style={styles.sectionCount}>{apps.length}</Text>
    </View>
    <View style={styles.sectionBody}>
      {apps.length === 0 ? (
        <Text style={styles.emptyText}>No apps blocked.</Text>
      ) : (
        apps.map(bundleID => (
          <View key={bundleID} style={styles.row}>
            <Text style={styles.rowDomain} numberOfLines={1}>{bundleID}</Text>
          </View>
        ))
      )}
    </View>
  </View>
);

// ─── Loaded content ────────────────────────────────────────────────────────

const RulesContent: React.FC<{rules: ActiveRules}> = ({rules}) => {
  const isAllowOnly = rules.mode === 'whiteList';
  const entriesTitle = isAllowOnly ? 'ALLOWED SITES' : 'BLOCKED SITES';
  const entriesBadge = isAllowOnly ? 'ALLOW' : 'BLOCKED';
  const entriesBadgeColor = isAllowOnly ? colors.success : colors.danger;

  return (
    <>
      <ModeCard mode={rules.mode} />

      <RulesSection
        title={entriesTitle}
        items={rules.entries}
        badge={entriesBadge}
        badgeColor={entriesBadgeColor}
        emptyLabel="No sites configured yet."
      />

      <RulesSection
        title="PATH EXCEPTIONS"
        items={rules.exceptions}
        badge="EXCEPTION"
        badgeColor={colors.warning}
        emptyLabel="No path exceptions configured."
      />

      <AllowedAppsSection apps={rules.allowedApps} />

      <BlockedAppsSection apps={rules.blockedApps} />
    </>
  );
};

// ─── Screen ────────────────────────────────────────────────────────────────

type Props = {
  visible: boolean;
  onClose: () => void;
};

export const ActiveRulesScreen: React.FC<Props> = ({visible, onClose}) => {
  const {state, reload} = useActiveRules();

  useEffect(() => {
    if (visible) {
      reload();
    }
  }, [visible, reload]);

  return (
    <Modal
      visible={visible}
      animationType="slide"
      presentationStyle="pageSheet"
      onRequestClose={onClose}>
      <SafeAreaView style={styles.root}>
        <View style={styles.navBar}>
          <Pressable onPress={onClose} style={styles.backButton} hitSlop={12}>
            <Text style={styles.backText}>‹ Back</Text>
          </Pressable>
          <Text style={styles.navTitle}>Active Rules</Text>
          <Pressable onPress={reload} style={styles.reloadButton} hitSlop={12}>
            <Text style={styles.reloadText}>Reload</Text>
          </Pressable>
        </View>

        <ScrollView contentContainerStyle={styles.scroll}>
          {state.kind === 'loading' && (
            <ActivityIndicator style={styles.loader} color={colors.info} />
          )}

          {state.kind === 'error' && (
            <Text style={styles.errorText}>{state.message}</Text>
          )}

          {state.kind === 'ready' && <RulesContent rules={state.rules} />}

          <Text style={styles.footer}>Read-only · managed by your admin</Text>
        </ScrollView>
      </SafeAreaView>
    </Modal>
  );
};

// ─── Styles ────────────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  root: {
    flex: 1,
    backgroundColor: colors.background,
  },
  navBar: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: spacing.lg,
    paddingVertical: spacing.md,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colors.separator,
  },
  backButton: {
    minWidth: 60,
  },
  backText: {
    ...typography.body,
    color: colors.info,
  },
  navTitle: {
    ...typography.headline,
    color: colors.label,
  },
  reloadButton: {
    minWidth: 60,
    alignItems: 'flex-end',
  },
  reloadText: {
    ...typography.body,
    color: colors.info,
  },
  scroll: {
    paddingBottom: spacing.xxl,
  },
  loader: {
    marginTop: spacing.xxl,
  },
  errorText: {
    ...typography.subhead,
    color: colors.danger,
    margin: spacing.lg,
  },

  // Mode card
  modeCard: {
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    marginHorizontal: spacing.lg,
    marginTop: spacing.lg,
    padding: spacing.md,
  },
  modeRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  modeLabel: {
    ...typography.headline,
    color: colors.label,
  },
  modeBadge: {
    borderRadius: radius.pill,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.xs,
  },
  modeBadgeText: {
    ...typography.caption,
  },
  modeDescription: {
    ...typography.subhead,
    color: colors.labelSecondary,
    marginTop: spacing.xs,
  },

  // Section
  section: {
    marginHorizontal: spacing.lg,
    marginTop: spacing.xl,
  },
  sectionHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginBottom: spacing.sm,
  },
  sectionTitle: {
    ...typography.caption,
    color: colors.labelSecondary,
    letterSpacing: 0.5,
  },
  sectionCount: {
    ...typography.caption,
    color: colors.labelSecondary,
  },
  sectionBody: {
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    overflow: 'hidden',
  },

  // Row
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colors.separator,
  },
  rowDomain: {
    ...typography.subhead,
    color: colors.label,
    flex: 1,
    marginRight: spacing.sm,
  },
  rowBadge: {
    borderRadius: radius.pill,
    paddingHorizontal: spacing.sm,
    paddingVertical: 2,
  },
  rowBadgeText: {
    fontSize: 10,
    fontWeight: '700',
  },
  emptyText: {
    ...typography.subhead,
    color: colors.labelSecondary,
    padding: spacing.md,
  },
  showMore: {
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
  },
  showMoreText: {
    ...typography.subhead,
    color: colors.info,
  },

  // Footer
  footer: {
    ...typography.caption,
    color: colors.labelSecondary,
    textAlign: 'center',
    marginTop: spacing.xl,
    paddingHorizontal: spacing.lg,
  },
});
