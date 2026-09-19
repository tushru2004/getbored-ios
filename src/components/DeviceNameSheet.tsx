import React, {useEffect, useState} from 'react';
import {
    ActivityIndicator,
    Modal,
    Pressable,
    StyleSheet,
    Text,
    TextInput,
    View,
} from 'react-native';

import {colors, hardShadow, spacing, typography} from '../theme';

type Props = {
    visible: boolean;
    /** Required at launch; optional when opened later from Account. */
    required: boolean;
    initialName: string;
    onSave: (displayName: string) => Promise<void>;
    onClose: () => void;
};

/**
 * One editor serves both name states:
 *
 *   no account-owned label at app launch → required, no escape path
 *   Account → This iPhone                 → optional rename with Cancel
 *
 * The parent owns visibility and updates the registration after a successful
 * PATCH, so a saved name immediately removes the required launch state.
 */
export const DeviceNameSheet: React.FC<Props> = ({
    visible,
    required,
    initialName,
    onSave,
    onClose,
}) => {
    const [name, setName] = useState(initialName);
    const [pending, setPending] = useState(false);
    const [error, setError] = useState<string | null>(null);

    useEffect(() => {
        if (visible) {
            setName(initialName);
            setPending(false);
            setError(null);
        }
    }, [visible, initialName]);

    const trimmedName = name.trim();
    const saveDisabled = pending || trimmedName.length === 0;

    async function save() {
        if (saveDisabled) return;
        setPending(true);
        setError(null);
        try {
            await onSave(trimmedName);
            if (!required) onClose();
        } catch (failure) {
            setError(failure instanceof Error ? failure.message : String(failure));
        } finally {
            setPending(false);
        }
    }

    return (
        <Modal
            visible={visible}
            transparent
            animationType="fade"
            onRequestClose={required ? () => undefined : onClose}>
            <View style={styles.backdrop}>
                <View style={styles.sheet}>
                    {!required ? <View style={styles.grabber} /> : null}
                    <Text style={styles.eyebrow}>{required ? 'One last thing' : 'This iPhone'}</Text>
                    <Text style={styles.title}>{required ? 'Name this iPhone' : 'Rename this iPhone'}</Text>
                    <Text style={styles.copy}>
                        {required
                            ? 'Give this phone a name before using GetBored. It helps you recognise it when assigning rules in your dashboard.'
                            : 'Use a name you will recognise in your dashboard when assigning rules.'}
                    </Text>

                    <Text style={styles.fieldLabel}>iPhone name</Text>
                    <TextInput
                        autoCapitalize="words"
                        autoComplete="off"
                        autoCorrect={false}
                        editable={!pending}
                        maxLength={40}
                        onChangeText={setName}
                        placeholder="For example, Work iPhone"
                        placeholderTextColor={colors.neutral}
                        returnKeyType="done"
                        style={styles.input}
                        value={name}
                    />
                    <Text style={styles.hint}>
                        This only changes how the phone appears in GetBored. You can change it later.
                    </Text>
                    {error ? <Text style={styles.error}>{error}</Text> : null}

                    <View style={styles.actions}>
                        <Pressable
                            disabled={saveDisabled}
                            onPress={() => { save(); }}
                            style={({pressed}) => [
                                styles.save,
                                (pressed || saveDisabled) && styles.dimmed,
                            ]}>
                            {pending ? <ActivityIndicator color={colors.label} /> : <Text style={styles.saveText}>{required ? 'Continue' : 'Save changes'}</Text>}
                        </Pressable>
                        {!required ? (
                            <Pressable disabled={pending} onPress={onClose} style={styles.cancel}>
                                <Text style={styles.cancelText}>Cancel</Text>
                            </Pressable>
                        ) : null}
                    </View>
                    {required ? <Text style={styles.requiredHint}>A name is required to continue.</Text> : null}
                </View>
            </View>
        </Modal>
    );
};

const styles = StyleSheet.create({
    backdrop: {
        backgroundColor: 'rgba(23, 52, 47, 0.52)',
        flex: 1,
        justifyContent: 'center',
        padding: spacing.lg,
    },
    sheet: {
        backgroundColor: colors.surface,
        borderColor: colors.label,
        borderWidth: 2,
        padding: spacing.xl,
        ...hardShadow,
    },
    grabber: {
        alignSelf: 'center',
        backgroundColor: colors.separator,
        borderRadius: 3,
        height: 5,
        marginBottom: spacing.lg,
        width: 36,
    },
    eyebrow: {
        ...typography.eyebrow,
        color: colors.label,
        marginBottom: spacing.sm,
    },
    title: {
        ...typography.display,
        color: colors.label,
        fontSize: 32,
        lineHeight: 36,
    },
    copy: {
        ...typography.subhead,
        color: colors.labelSecondary,
        lineHeight: 20,
        marginTop: spacing.md,
    },
    fieldLabel: {
        ...typography.eyebrow,
        color: colors.label,
        marginBottom: spacing.sm,
        marginTop: spacing.xl,
    },
    input: {
        backgroundColor: colors.surface,
        borderColor: colors.label,
        borderWidth: 1,
        color: colors.label,
        fontFamily: 'Iowan Old Style',
        fontSize: 19,
        minHeight: 50,
        paddingHorizontal: spacing.md,
    },
    hint: {
        ...typography.subhead,
        color: colors.labelSecondary,
        lineHeight: 18,
        marginTop: spacing.sm,
    },
    error: {
        ...typography.subhead,
        color: colors.danger,
        lineHeight: 18,
        marginTop: spacing.md,
    },
    actions: {
        flexDirection: 'row',
        gap: spacing.md,
        marginTop: spacing.xl,
    },
    save: {
        ...hardShadow,
        alignItems: 'center',
        backgroundColor: colors.sun,
        borderColor: colors.label,
        borderWidth: 2,
        flex: 1,
        justifyContent: 'center',
        minHeight: 48,
    },
    saveText: {
        ...typography.eyebrow,
        color: colors.label,
    },
    cancel: {
        alignItems: 'center',
        borderColor: colors.label,
        borderWidth: 1,
        justifyContent: 'center',
        minHeight: 48,
        paddingHorizontal: spacing.lg,
    },
    cancelText: {
        ...typography.eyebrow,
        color: colors.label,
    },
    dimmed: {
        opacity: 0.45,
    },
    requiredHint: {
        ...typography.microFooter,
        color: colors.labelSecondary,
        marginTop: spacing.md,
        textAlign: 'center',
    },
});
