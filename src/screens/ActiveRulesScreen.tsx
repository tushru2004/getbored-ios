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
import {colors, spacing, typography} from '../theme';

const INITIAL_VISIBLE = 5;

// ─── App names ─────────────────────────────────────────────────────────────

/** Humans see "Instagram", not "com.burbn.instagram". The raw bundle id
 * stays visible in the web admin, where identification matters. */
const KNOWN_APP_NAMES: Record<string, string> = {
  'com.burbn.instagram': 'Instagram',
  'com.zhiliaoapp.musically': 'TikTok',
  'com.google.ios.youtube': 'YouTube',
  'com.atebits.Tweetie2': 'X',
  'com.reddit.Reddit': 'Reddit',
  'com.toyopagroup.picaboo': 'Snapchat',
  'com.facebook.Facebook': 'Facebook',
  'net.whatsapp.WhatsApp': 'WhatsApp',
  'com.netflix.Netflix': 'Netflix',
  'com.hammerandchisel.discord': 'Discord',
  'ph.telegra.Telegraph': 'Telegram',
  'com.linkedin.LinkedIn': 'LinkedIn',
  'com.duowan.amazing': 'Twitch',
  'tv.twitch': 'Twitch',
};

function appDisplayName(bundleID: string): string {
  const known = KNOWN_APP_NAMES[bundleID];
  if (known) {
    return known;
  }
  // Fallback: last dot-component, capitalized ("com.example.somegame" →
  // "Somegame"). Imperfect, but better than a reverse-DNS string.
  const last = bundleID.split('.').pop() ?? bundleID;
  return last.charAt(0).toUpperCase() + last.slice(1);
}

// ─── Mode line ─────────────────────────────────────────────────────────────

/** One quiet sentence states the mode once — no card, no badge, and no
 * per-row pills repeating it. */
function modeLine(mode: ActiveRules['mode']): string {
  if (mode === 'whiteList') {
    return 'Allowing only the sites below · everything else is blocked';
  }
  return 'Blocking the sites below · everything else is allowed';
}

// ─── Section ───────────────────────────────────────────────────────────────

type SectionProps = {
  title: string;
  items: string[];
};

/**
 * A plain hairline list with a "Show N more" expander. Renders NOTHING when
 * empty — sections that would only announce absence don't earn screen space;
 * callers simply skip them.
 */
const RulesSection: React.FC<SectionProps> = ({title, items}) => {
  const [showAll, setShowAll] = useState(false);

  if (items.length === 0) {
    return null;
  }

  const visible = showAll ? items : items.slice(0, INITIAL_VISIBLE);
  const hiddenCount = items.length - INITIAL_VISIBLE;

  return (
    <View style={styles.section}>
      <View style={styles.sectionHeader}>
        <Text style={styles.sectionTitle}>{title}</Text>
        <Text style={styles.sectionCount}>{items.length}</Text>
      </View>
      <View style={styles.sectionRows}>
        {visible.map(item => (
          <View key={item} style={styles.row}>
            <Text style={styles.rowText} numberOfLines={1}>
              {item}
            </Text>
          </View>
        ))}
        {!showAll && hiddenCount > 0 && (
          <Pressable onPress={() => setShowAll(true)} style={styles.row}>
            <Text style={styles.showMoreText}>Show {hiddenCount} more</Text>
          </Pressable>
        )}
      </View>
    </View>
  );
};

// ─── Loaded content ────────────────────────────────────────────────────────

const RulesContent: React.FC<{rules: ActiveRules}> = ({rules}) => {
  const isAllowOnly = rules.mode === 'whiteList';
  const entriesTitle = isAllowOnly ? 'Allowed sites' : 'Blocked sites';
  const hasAnything =
    rules.entries.length > 0 ||
    rules.exceptions.length > 0 ||
    rules.allowedApps.length > 0 ||
    rules.blockedApps.length > 0;

  if (!hasAnything) {
    return (
      <Text style={styles.emptyState}>
        No rules yet · assign a list in your admin
      </Text>
    );
  }

  return (
    <>
      <Text style={styles.modeLine}>{modeLine(rules.mode)}</Text>
      <RulesSection title={entriesTitle} items={rules.entries} />
      <RulesSection title="Path exceptions" items={rules.exceptions} />
      <RulesSection
        title="Allowed apps"
        items={rules.allowedApps.map(appDisplayName)}
      />
      <RulesSection
        title="Blocked apps"
        items={rules.blockedApps.map(appDisplayName)}
      />
    </>
  );
};

// ─── Screen ────────────────────────────────────────────────────────────────

type Props = {
  visible: boolean;
  onClose: () => void;
};

/**
 * Read-only modal listing the device's active filter rules.
 *
 *   visible prop toggles
 *       │
 *       └── useEffect: visible === true → reload()   ← re-fetches on every open,
 *                                                       so the sheet never shows
 *                                                       stale rules from a prior open
 *       (reload also fired manually by the nav-bar "Reload" button)
 *
 *   useActiveRules().state drives the body:
 *       │
 *       ├── 'loading' → ActivityIndicator
 *       ├── 'error'   → error message
 *       └── 'ready'   → <RulesContent rules={state.rules} />
 */
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
          {state.kind === 'signedOut' && (
            <Text style={styles.noticeText}>
              Sign in again to view your active rules.
            </Text>
          )}
          {state.kind === 'subscriptionRequired' && (
            <Text style={styles.noticeText}>
              Filtering has stopped until your subscription is active again.
            </Text>
          )}

          {state.kind === 'ready' && <RulesContent rules={state.rules} />}

          <Text style={styles.footer}>Read-only · synced from your account</Text>
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
    paddingHorizontal: spacing.xl,
    paddingBottom: spacing.xxl,
  },
  loader: {
    marginTop: spacing.xxl,
  },
  errorText: {
    ...typography.subhead,
    color: colors.danger,
    marginTop: spacing.lg,
  },
  noticeText: {
    ...typography.subhead,
    color: colors.labelSecondary,
    marginTop: spacing.lg,
  },
  modeLine: {
    ...typography.subhead,
    fontSize: 14,
    color: colors.labelSecondary,
    marginTop: spacing.lg,
  },
  emptyState: {
    ...typography.subhead,
    fontSize: 14,
    color: colors.labelSecondary,
    textAlign: 'center',
    marginTop: spacing.xxl * 2,
  },
  section: {
    marginTop: spacing.xl,
  },
  sectionHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginBottom: spacing.xs,
  },
  sectionTitle: {
    fontSize: 11,
    fontWeight: '600',
    letterSpacing: 0.9,
    textTransform: 'uppercase',
    color: colors.neutral,
  },
  sectionCount: {
    fontSize: 11,
    fontWeight: '600',
    color: colors.neutral,
    fontVariant: ['tabular-nums'],
  },
  sectionRows: {
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: colors.separator,
  },
  row: {
    paddingVertical: spacing.md + 2,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colors.separator,
  },
  rowText: {
    fontSize: 15,
    fontWeight: '400',
    color: colors.label,
  },
  showMoreText: {
    fontSize: 15,
    fontWeight: '500',
    color: colors.info,
  },
  footer: {
    ...typography.caption,
    fontWeight: '400',
    color: colors.neutral,
    textAlign: 'center',
    marginTop: spacing.xxl,
  },
});
