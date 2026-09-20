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
import {ActiveRules, AssignedPolicyList} from '../native/types';
import {colors, hardShadow, spacing, typography} from '../theme';

const INITIAL_VISIBLE = 6;
const APP_NAMES: Record<string, string> = {
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
const appName = (id: string) => APP_NAMES[id] ?? id.split('.').pop() ?? id;
const listName = (list: AssignedPolicyList) =>
  list.name?.trim() ||
  (list.mode === 'whiteList' ? 'Allow list' : 'Block list');
const itemCount = (list: AssignedPolicyList) =>
  list.entries.length +
  list.exceptions.length +
  list.allowedApps.length +
  list.blockedApps.length;
const dateText = (time: number, timezone?: string) =>
  new Intl.DateTimeFormat(undefined, {
    weekday: 'short',
    hour: 'numeric',
    minute: '2-digit',
    timeZone: timezone,
    timeZoneName:
      timezone && timezone !== Intl.DateTimeFormat().resolvedOptions().timeZone
        ? 'short'
        : undefined,
  }).format(new Date(time));

function timing(list: AssignedPolicyList, active: boolean): string {
  if (!list.schedule || list.schedule.mode === 'always')
    return 'Active all the time';
  if (list.schedule.intervals.length === 0) return 'No times scheduled';
  if (active && list.activeUntil)
    return `Until ${dateText(list.activeUntil, list.schedule.timezone)}`;
  if (list.nextStartAt)
    return `Starts ${dateText(list.nextStartAt, list.schedule.timezone)}`;
  return 'Scheduled';
}

const ItemGroup: React.FC<{caption: string; items: string[]}> = ({
  caption,
  items,
}) => {
  const [expanded, setExpanded] = useState(false);
  if (!items.length) return null;
  const shown = expanded ? items : items.slice(0, INITIAL_VISIBLE);
  return (
    <View style={styles.itemGroup}>
      <Text style={styles.itemCaption}>
        {caption} · {items.length}
      </Text>
      {shown.map(item => (
        <Text key={item} style={styles.item}>
          {item}
        </Text>
      ))}
      {!expanded && items.length > INITIAL_VISIBLE && (
        <Pressable onPress={() => setExpanded(true)}>
          <Text style={styles.expand}>
            Show {items.length - INITIAL_VISIBLE} more
          </Text>
        </Pressable>
      )}
    </View>
  );
};

const PolicyRow: React.FC<{list: AssignedPolicyList; active: boolean}> = ({
  list,
  active,
}) => {
  const [expanded, setExpanded] = useState(false);
  const count = itemCount(list);
  const sites = list.entries.length + list.exceptions.length;
  const apps = list.allowedApps.length + list.blockedApps.length;
  const contents =
    [
      sites > 0 ? `${sites} ${sites === 1 ? 'site' : 'sites'}` : null,
      apps > 0 ? `${apps} ${apps === 1 ? 'app' : 'apps'}` : null,
    ]
      .filter(Boolean)
      .join(' · ') || 'No sites or apps';
  return (
    <View style={styles.policyRow}>
      <View style={styles.policyTop}>
        <View style={styles.policyCopy}>
          <Text style={styles.policyName}>{listName(list)}</Text>
          <Text style={styles.detail}>
            {contents} · {timing(list, active)}
          </Text>
        </View>
        <Text
          style={[
            styles.badge,
            active ? styles.activeBadge : styles.scheduledBadge,
          ]}>
          {active ? 'ACTIVE' : 'SCHEDULED'}
        </Text>
      </View>
      <Text
        style={[
          styles.modeTag,
          list.mode === 'whiteList' ? styles.allowTag : styles.blockTag,
        ]}>
        {list.mode === 'whiteList' ? 'ALLOW' : 'BLOCK'}
      </Text>
      {count > 0 && (
        <Pressable onPress={() => setExpanded(!expanded)}>
          <Text style={styles.expand}>
            {expanded ? 'Hide details' : 'Show details'}
          </Text>
        </Pressable>
      )}
      {expanded && (
        <View style={styles.details}>
          <ItemGroup
            caption={
              list.mode === 'whiteList' ? 'Allowed sites' : 'Blocked sites'
            }
            items={list.entries}
          />
          <ItemGroup caption="Allowed paths" items={list.exceptions} />
          <ItemGroup
            caption="Allowed apps"
            items={list.allowedApps.map(appName)}
          />
          <ItemGroup
            caption="Blocked apps"
            items={list.blockedApps.map(appName)}
          />
        </View>
      )}
    </View>
  );
};

const RulesContent: React.FC<{rules: ActiveRules}> = ({rules}) => {
  if (rules.presentationState === 'malformed')
    return (
      <Text style={styles.notice}>
        This device’s scheduled policy could not be read. It is not shown as an
        empty rule set.
      </Text>
    );
  const legacy = rules.presentationState !== 'scheduled';
  const legacyList: AssignedPolicyList = {
    id: 'legacy',
    mode: rules.mode,
    entries: rules.entries,
    exceptions: rules.exceptions,
    allowedApps: rules.allowedApps,
    blockedApps: rules.blockedApps,
    activeNow: true,
  };
  const assignedLists = rules.assignedLists ?? [];
  const active = assignedLists.filter(list => list.activeNow);
  const upcoming = assignedLists
    .filter(list => !list.activeNow)
    .sort(
      (a, b) =>
        (a.nextStartAt ?? Number.MAX_SAFE_INTEGER) -
        (b.nextStartAt ?? Number.MAX_SAFE_INTEGER),
    );
  return (
    <>
      <View style={styles.card}>
        <View style={styles.sectionHead}>
          <Text style={styles.sectionTitle}>Active now</Text>
          <Text style={styles.count}>
            {legacy ? 'Current policy' : `${active.length} active`}
          </Text>
        </View>
        {legacy ? (
          <PolicyRow list={legacyList} active />
        ) : active.length ? (
          active.map(list => <PolicyRow key={list.id} list={list} active />)
        ) : (
          <Text style={styles.empty}>
            No scheduled lists are active right now.
          </Text>
        )}
        {!legacy && upcoming.length > 0 && (
          <>
            <View style={styles.sectionHead}>
              <Text style={styles.sectionTitle}>Up next</Text>
              <Text style={styles.count}>{upcoming.length} planned</Text>
            </View>
            {upcoming.map(list => (
              <PolicyRow key={list.id} list={list} active={false} />
            ))}
          </>
        )}
      </View>
      {!legacy && (
        <Text style={styles.notice}>
          Scheduled lists are not active until their start time.
        </Text>
      )}
    </>
  );
};

export const ActiveRulesScreen: React.FC<{
  visible: boolean;
  onClose: () => void;
}> = ({visible, onClose}) => {
  const {state, reload} = useActiveRules({refreshing: visible});
  useEffect(() => {
    if (visible) reload();
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
              <Text style={styles.backText}>← Home</Text>
            </Pressable>
          </View>
          <View style={styles.titleBlock}>
            <Text style={styles.eyebrow}>Policy on this iPhone</Text>
            <Text style={styles.bigTitle}>Your rules</Text>
          </View>
          {state.kind === 'loading' && (
            <ActivityIndicator style={styles.loader} color={colors.info} />
          )}
          {state.kind === 'error' && (
            <Text style={styles.error}>{state.message}</Text>
          )}
          {state.kind === 'signedOut' && (
            <Text style={styles.notice}>Sign in again to view your rules.</Text>
          )}
          {state.kind === 'subscriptionRequired' && (
            <Text style={styles.notice}>
              Filtering has stopped until your subscription is active again.
            </Text>
          )}
          {state.kind === 'ready' && <RulesContent rules={state.rules} />}
          <Text style={styles.footer}>Synced from your account</Text>
        </ScrollView>
      </SafeAreaView>
    </Modal>
  );
};

const styles = StyleSheet.create({
  root: {flex: 1, backgroundColor: colors.background},
  scroll: {
    flexGrow: 1,
    paddingHorizontal: spacing.xl,
    paddingBottom: spacing.xxl,
  },
  navRow: {
    minHeight: 48,
    justifyContent: 'center',
    borderBottomWidth: 1,
    borderBottomColor: colors.separator,
  },
  backText: {...typography.eyebrow, color: colors.label},
  titleBlock: {
    marginTop: spacing.lg,
    paddingBottom: spacing.lg,
    borderBottomWidth: 2,
    borderBottomColor: colors.label,
  },
  eyebrow: {...typography.eyebrow, color: colors.label},
  bigTitle: {
    ...typography.display,
    fontSize: 36,
    color: colors.label,
    marginTop: spacing.sm,
  },
  loader: {marginTop: spacing.xxl},
  error: {...typography.subhead, color: colors.danger, marginTop: spacing.lg},
  card: {
    ...hardShadow,
    marginTop: spacing.xl,
    backgroundColor: colors.surface,
    borderWidth: 1,
    borderColor: colors.label,
  },
  sectionHead: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    padding: spacing.md,
    borderBottomWidth: 1,
    borderBottomColor: colors.separator,
  },
  sectionTitle: {...typography.display, fontSize: 19, color: colors.label},
  count: {...typography.eyebrow, color: colors.labelSecondary},
  policyRow: {
    padding: spacing.md,
    borderBottomWidth: 1,
    borderBottomColor: colors.separator,
  },
  policyTop: {
    flexDirection: 'row',
    gap: spacing.sm,
    justifyContent: 'space-between',
  },
  policyCopy: {flex: 1},
  policyName: {...typography.display, fontSize: 17, color: colors.label},
  detail: {
    ...typography.subhead,
    fontSize: 12,
    lineHeight: 17,
    color: colors.labelSecondary,
    marginTop: 3,
  },
  badge: {
    ...typography.eyebrow,
    fontSize: 9,
    paddingHorizontal: 6,
    paddingVertical: 4,
    alignSelf: 'flex-start',
  },
  activeBadge: {backgroundColor: colors.sun, color: colors.label},
  scheduledBadge: {
    backgroundColor: colors.background,
    color: colors.labelSecondary,
  },
  modeTag: {
    ...typography.eyebrow,
    fontSize: 9,
    paddingHorizontal: 6,
    paddingVertical: 4,
    alignSelf: 'flex-start',
    marginTop: spacing.sm,
  },
  allowTag: {backgroundColor: '#DDEBDF', color: colors.success},
  blockTag: {backgroundColor: '#F1DEDA', color: colors.danger},
  expand: {
    ...typography.eyebrow,
    fontSize: 10,
    color: colors.label,
    marginTop: spacing.md,
  },
  details: {marginTop: spacing.sm},
  itemGroup: {marginTop: spacing.sm},
  itemCaption: {
    ...typography.eyebrow,
    fontSize: 10,
    color: colors.labelSecondary,
  },
  item: {
    ...typography.subhead,
    fontSize: 13,
    color: colors.label,
    paddingTop: 3,
  },
  empty: {
    ...typography.subhead,
    fontSize: 13,
    color: colors.labelSecondary,
    padding: spacing.md,
  },
  notice: {
    ...typography.subhead,
    fontSize: 13,
    lineHeight: 18,
    color: colors.labelSecondary,
    marginTop: spacing.lg,
  },
  footer: {
    ...typography.microFooter,
    color: colors.neutral,
    textAlign: 'center',
    marginTop: 'auto',
    paddingTop: spacing.xxl,
  },
});
