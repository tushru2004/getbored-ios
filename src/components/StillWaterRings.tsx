import React from 'react';
import {StyleSheet, View} from 'react-native';

type Variant = 'closed' | 'open';

type Props = {
    /** Outer diameter in points (the mock uses 120 on the home hero). */
    size: number;
    color: string;
    /**
     * 'closed' — solid rings settling around a filled center: protected/calm.
     * 'open'  — dashed inner ring and a hollow center: attention needed.
     */
    variant: Variant;
};

        /**
         * The "Still Water" identity mark: concentric rings settling around a center
         * point, like a pond going still. Drawn with plain bordered Views (no SVG
         * dependency) — circles are the one shape Views render perfectly.
         *
         * Ring geometry mirrors the approved HTML mock (radii 55/40/25/10 at
         * size 120), with opacity increasing toward the center.
         */
        export const StillWaterRings: React.FC<Props> = ({size, color, variant}) => {
            const borderWidth = Math.max(2, size * 0.022);
            const ring = (diameterRatio: number, opacity: number, dashed: boolean) => {
                const diameter = size * diameterRatio;
                return (
                    <View
                        style={[
                            styles.ring,
                            {
                                width: diameter,
                                height: diameter,
                                borderRadius: diameter / 2,
                                borderColor: color,
                                borderWidth,
                                borderStyle: dashed ? 'dashed' : 'solid',
                                opacity,
                            },
                        ]}
                    />
                );
            };

            const dotDiameter = size * (10 / 60);
            const open = variant === 'open';

            return (
                <View style={[styles.box, {width: size, height: size}]}>
                    {ring(55 / 60, 0.25, false)}
                    {ring(40 / 60, 0.55, false)}
                    {ring(25 / 60, 1, open)}
                    <View
                        style={[
                            styles.ring,
                            {
                                width: dotDiameter,
                                height: dotDiameter,
                                borderRadius: dotDiameter / 2,
                                backgroundColor: open ? 'transparent' : color,
                                borderColor: color,
                                borderWidth: open ? borderWidth : 0,
                            },
                        ]}
                    />
                </View>
            );
        };

const styles = StyleSheet.create({
    box: {
        alignItems: 'center',
        justifyContent: 'center',
    },
    ring: {
        position: 'absolute',
    },
});
