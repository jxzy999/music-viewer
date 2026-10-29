# GeneralUser GS compatibility changes for Music Viewer

Original: GeneralUser GS 2.0.3 by S. Christian Collins, License 2.0.
Source: https://github.com/mrbumpy409/GeneralUser-GS
Commit: 684543d5e5efaef08d02be50dcda8d552478fa60
The original license is preserved in GeneralUser-GS-LICENSE.txt.

Music Viewer normalizes the key and velocity ranges of bank 0 / program 0
(Grand Piano) for Apple's AUSampler. Each preset zone refers to a private
instrument whose sample zones are already intersected with that preset's
ranges. Empty intersections are omitted. This prevents extra samples from
being activated by the native SoundFont importer and exhausting its sample pool.

All original PCM samples, sample headers, other generators and modulators,
original instruments, and the other 286 presets are retained. No recordings
were added or replaced. The result is a modified compatibility version.

Reproduction script: script/prepare_builtin_soundfont.py in the Music Viewer
source repository. It checks the original input and produces deterministic output.

Original SHA-256:
9575028c7a1f589f5770fccc8cff2734566af40cd26ed836944e9a5152688cfe

Compatibility version SHA-256:
baaae7f10324582107051c8a23acf014d163a5118ac2e0250b3bc2fe0c0e2e40
