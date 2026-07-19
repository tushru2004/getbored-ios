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
import {colors, spacing, typography, withAlpha} from '../theme';

const INITIAL_VISIBLE = 8;

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

/** One quiet sentence states the mode once, as the title's subtitle. */
function modeLine(mode: ActiveRules['mode']): string {
  if (mode === 'whiteList') {
    return 'Allowing only the items below · everything else is blocked';
  }
  return 'Blocking the items below · everything else is allowed';
}

// ─── Rule row ──────────────────────────────────────────────────────────────

/**
 * A rule as a tangible object: serif monogram in a pine-tinted circle,
 * name at 17pt. The monogram gives sparse lists physical presence — one
 * rule reads as one calm object, not one lonely text line.
 */
const RuleRow: React.FC<{name: string}> = ({name}) => (
  <View style={styles.rule}>
    <View style={styles.monogram}>
      <Text style={styles.monogramText}>{name.charAt(0).toUpperCase()}</Text>
    </View>
    <Text style={styles.ruleName} numberOfLines={1}>
      {name}
    </Text>
  </View>
);

// ─── Group ─────────────────────────────────────────────────────────────────

type GroupProps = {
  caption: string;
  items: string[];
};

/**
 * A captioned group of monogram rows with a "Show N more" expander.
 * Renders NOTHING when empty — absence doesn't earn screen space.
 */
const RulesGroup: React.FC<GroupProps> = ({caption, items}) => {
  const [showAll, setShowAll] = useState(false);

  if (items.length === 0) {
    return null;
  }

  const visible = showAll ? items : items.slice(0, INITIAL_VISIBLE);
  const hiddenCount = items.length - INITIAL_VISIBLE;

  return (
    <View style={styles.group}>
      <View style={styles.groupCaption}>
        <Text style={styles.groupCaptionText}>{caption}</Text>
        <Text style={styles.groupCaptionCount}>{items.length}</Text>
      </View>
      {visible.map(item => (
        <RuleRow key={item} name={item} />
      ))}
      {!showAll && hiddenCount > 0 && (
        <Pressable onPress={() => setShowAll(true)} style={styles.showMore}>
          <Text style={styles.showMoreText}>Show {hiddenCount} more</Text>
        </Pressable>
      )}
    </View>
  );
};

// ─── Loaded content ────────────────────────────────────────────────────────

const RulesContent: React.FC<{rules: ActiveRules}> = ({rules}) => {
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
      <Text style={styles.titleSub}>{modeLine(rules.mode)}</Text>
      <RulesGroup caption="Sites" items={rules.entries} />
      <RulesGroup caption="Path exceptions" items={rules.exceptions} />
      <RulesGroup
        caption="Allowed apps"
        items={rules.allowedApps.map(appDisplayName)}
      />
      <RulesGroup caption="Apps" items={rules.blockedApps.map(appDisplayName)} />
    </>
  );
};

// ─── Screen ────────────────────────────────────────────────────────────────

type Props = {
  visible: boolean;
  onClose: () => void;
};

/**
 * Read-only modal listing the device's active filter rules, in the brand's
 * voice: serif "Your rules" title, mode as its subtitle, monogram rows in
 * captioned groups. No Reload control — rules re-fetch on every open, and
 * the home screen's auto/pull-to-refresh sync keeps them current.
 *
 *   visible prop toggles
 *       │
 *       └── useEffect: visible === true → reload()
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
        <ScrollView contentContainerStyle={styles.scroll}>
          <View style={styles.navRow}>
            <Pressable onPress={onClose} hitSlop={12}>
              <Text style={styles.backText}>‹ Back</Text>
            </Pressable>
          </View>
          <Text style={styles.bigTitle}>Your rules</Text>

          {state.kind === 'loading' && (
            <ActivityIndicator style={styles.loader} color={colors.info} />
          )}
          {state.kind === 'error' && (
            <Text style={styles.errorText}>{state.message}</Text>
          )}
          {state.kind === 'signedOut' && (
            <Text style={styles.noticeText}>
              Sign in again to view your rules.
            </Text>
          )}
          {state.kind === 'subscriptionRequired' && (
            <Text style={styles.noticeText}>
              Filtering has stopped until your subscription is active again.
            </Text>
          )}

          {state.kind === 'ready' && <RulesContent rules={state.rules} />}

          <Text style={styles.footer}>
            Synced from your account · read-only
          </Text>
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
  scroll: {
    flexGrow: 1,
    paddingHorizontal: spacing.xl,
    paddingBottom: spacing.xxl,
  },
  navRow: {
    flexDirection: 'row',
    paddingTop: spacing.md,
  },
  backText: {
    ...typography.body,
    color: colors.info,
  },
  bigTitle: {
    ...typography.wordmarkLarge,
    fontSize: 32,
    color: colors.label,
    marginTop: spacing.xl,
  },
  titleSub: {
    ...typography.subhead,
    fontSize: 13.5,
    lineHeight: 19,
    color: colors.labelSecondary,
    marginTop: spacing.xs + 2,
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
  emptyState: {
    ...typography.subhead,
    fontSize: 14,
    color: colors.labelSecondary,
    textAlign: 'center',
    marginTop: spacing.xxl * 2,
  },
  group: {
    marginTop: spacing.xl,
  },
  groupCaption: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginBottom: spacing.xs,
  },
  groupCaptionText: {
    fontSize: 11,
    fontWeight: '600',
    letterSpacing: 0.9,
    textTransform: 'uppercase',
    color: colors.neutral,
  },
  groupCaptionCount: {
    fontSize: 11,
    fontWeight: '600',
    color: colors.neutral,
    fontVariant: ['tabular-nums'],
  },
  rule: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md + 2,
    paddingVertical: spacing.md + 1,
  },
  monogram: {
    width: 44,
    height: 44,
    borderRadius: 22,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: withAlpha(colors.info, 0.1),
  },
  monogramText: {
    fontFamily: 'Georgia',
    fontSize: 19,
    fontWeight: '600',
    color: colors.info,
  },
  ruleName: {
    fontSize: 17,
    fontWeight: '500',
    color: colors.label,
    flexShrink: 1,
  },
  showMore: {
    paddingVertical: spacing.md,
    paddingLeft: 44 + spacing.md + 2,
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
    marginTop: 'auto',
    paddingTop: spacing.xxl,
  },
});
