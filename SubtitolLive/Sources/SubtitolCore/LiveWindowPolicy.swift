import Foundation

public enum LiveWindowPolicy {
    public static let minimumAudioSeconds: TimeInterval = 0.35
    /// Recognition may run faster internally, but new full-window hypotheses are not
    /// useful to a reader every 80 ms. A 180 ms hop gives the stabilizer independent
    /// observations without continuously churning the visible suffix.
    public static let minimumHopSeconds: TimeInterval = 0.18
    /// Audio each live hypothesis sees, when the manifest does not say. The Conformer
    /// learnt from clips of up to 15 s and needs context: from 4 s to 6 s its errors
    /// halve, and 7 s is the most it takes before the text arrives later.
    public static let liveWindowSeconds: TimeInterval = 7.0
    /// Audio the correction after Stop decodes. Never less than the live window: the
    /// final pass must not hear less than the hypotheses it replaces.
    public static let finalWindowSeconds: TimeInterval = 7.0
    public static let warmupWindowSeconds: [TimeInterval] = [liveWindowSeconds]
}
