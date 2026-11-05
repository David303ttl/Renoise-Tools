-- SPDX-License-Identifier: GPL-3.0-only
-- Curated root-relative scale definitions with unique memberships.
return {
  -- Diatonic modes.
  {name="Major", category="Diatonic Modes", intervals={0, 2, 4, 5, 7, 9, 11}, aliases={"Ionian", "Bilawal Thaat"}},
  {name="Dorian", category="Diatonic Modes", intervals={0, 2, 3, 5, 7, 9, 10}, aliases={"Kafi Thaat"}},
  {name="Phrygian", category="Diatonic Modes", intervals={0, 1, 3, 5, 7, 8, 10}, aliases={"Bhairavi Thaat"}},
  {name="Lydian", category="Diatonic Modes", intervals={0, 2, 4, 6, 7, 9, 11}, aliases={"Kalyan Thaat"}},
  {name="Mixolydian", category="Diatonic Modes", intervals={0, 2, 4, 5, 7, 9, 10}, aliases={"Khamaj Thaat"}},
  {name="Natural Minor", category="Diatonic Modes", intervals={0, 2, 3, 5, 7, 8, 10}, aliases={"Aeolian", "Asavari Thaat"}},
  {name="Locrian", category="Diatonic Modes", intervals={0, 1, 3, 5, 6, 8, 10}, aliases={}},

  -- Modes of melodic minor.
  {name="Melodic Minor", category="Melodic Minor Modes", intervals={0, 2, 3, 5, 7, 9, 11}, aliases={"Jazz Minor"}},
  {name="Dorian b2", category="Melodic Minor Modes", intervals={0, 1, 3, 5, 7, 9, 10}, aliases={"Phrygian Natural 6"}},
  {name="Lydian Augmented", category="Melodic Minor Modes", intervals={0, 2, 4, 6, 8, 9, 11}, aliases={}},
  {name="Lydian Dominant", category="Melodic Minor Modes", intervals={0, 2, 4, 6, 7, 9, 10}, aliases={"Acoustic Scale", "Overtone Scale"}},
  {name="Mixolydian b6", category="Melodic Minor Modes", intervals={0, 2, 4, 5, 7, 8, 10}, aliases={}},
  {name="Locrian #2", category="Melodic Minor Modes", intervals={0, 2, 3, 5, 6, 8, 10}, aliases={"Half-Diminished Scale"}},
  {name="Altered", category="Melodic Minor Modes", intervals={0, 1, 3, 4, 6, 8, 10}, aliases={"Super Locrian"}},

  -- Modes of harmonic minor.
  {name="Harmonic Minor", category="Harmonic Minor Modes", intervals={0, 2, 3, 5, 7, 8, 11}, aliases={}},
  {name="Locrian Natural 6", category="Harmonic Minor Modes", intervals={0, 1, 3, 5, 6, 9, 10}, aliases={}},
  {name="Ionian Augmented", category="Harmonic Minor Modes", intervals={0, 2, 4, 5, 8, 9, 11}, aliases={}},
  {name="Dorian #4", category="Harmonic Minor Modes", intervals={0, 2, 3, 6, 7, 9, 10}, aliases={"Romanian Minor", "Ukrainian Dorian"}},
  {name="Phrygian Dominant", category="Harmonic Minor Modes", intervals={0, 1, 4, 5, 7, 8, 10}, aliases={"Spanish Phrygian", "Spanish Gypsy"}},
  {name="Lydian #2", category="Harmonic Minor Modes", intervals={0, 3, 4, 6, 7, 9, 11}, aliases={}},
  {name="Ultralocrian", category="Harmonic Minor Modes", intervals={0, 1, 3, 4, 6, 8, 9}, aliases={}},

  -- Modes of harmonic major.
  {name="Harmonic Major", category="Harmonic Major Modes", intervals={0, 2, 4, 5, 7, 8, 11}, aliases={}},
  {name="Dorian b5", category="Harmonic Major Modes", intervals={0, 2, 3, 5, 6, 9, 10}, aliases={}},
  {name="Phrygian b4", category="Harmonic Major Modes", intervals={0, 1, 3, 4, 7, 8, 10}, aliases={}},
  {name="Lydian b3", category="Harmonic Major Modes", intervals={0, 2, 3, 6, 7, 9, 11}, aliases={}},
  {name="Mixolydian b2", category="Harmonic Major Modes", intervals={0, 1, 4, 5, 7, 9, 10}, aliases={}},
  {name="Lydian Augmented #2", category="Harmonic Major Modes", intervals={0, 3, 4, 6, 8, 9, 11}, aliases={}},
  {name="Locrian bb7", category="Harmonic Major Modes", intervals={0, 1, 3, 5, 6, 8, 9}, aliases={}},

  -- Double harmonic and related modes.
  {name="Double Harmonic Major", category="Double Harmonic Modes", intervals={0, 1, 4, 5, 7, 8, 11}, aliases={"Byzantine", "Bhairav Thaat"}},
  {name="Lydian #2 #6", category="Double Harmonic Modes", intervals={0, 3, 4, 6, 7, 10, 11}, aliases={}},
  {name="Ultraphrygian", category="Double Harmonic Modes", intervals={0, 1, 3, 4, 7, 8, 9}, aliases={}},
  {name="Hungarian Minor", category="Double Harmonic Modes", intervals={0, 2, 3, 6, 7, 8, 11}, aliases={"Gypsy Minor", "Double Harmonic Minor"}},
  {name="Oriental", category="Double Harmonic Modes", intervals={0, 1, 4, 5, 6, 9, 10}, aliases={}},
  {name="Ionian #2 #5", category="Double Harmonic Modes", intervals={0, 3, 4, 5, 8, 9, 11}, aliases={}},
  {name="Locrian bb3 bb7", category="Double Harmonic Modes", intervals={0, 1, 2, 5, 6, 8, 9}, aliases={}},

  -- Common pentatonic and folk collections.
  {name="Major Pentatonic", category="Pentatonic", intervals={0, 2, 4, 7, 9}, aliases={"Chinese Pentatonic"}},
  {name="Minor Pentatonic", category="Pentatonic", intervals={0, 3, 5, 7, 10}, aliases={}},
  {name="Suspended Pentatonic", category="Pentatonic", intervals={0, 2, 5, 7, 10}, aliases={"Egyptian"}},
  {name="Major Blues", category="Blues", intervals={0, 2, 3, 4, 7, 9}, aliases={}},
  {name="Blues", category="Blues", intervals={0, 3, 5, 6, 7, 10}, aliases={"Minor Blues"}},
  {name="Hirajoshi", category="Japanese Scales", intervals={0, 2, 3, 7, 8}, aliases={}},
  {name="In", category="Japanese Scales", intervals={0, 1, 5, 7, 8}, aliases={"Miyako-bushi"}},
  {name="Iwato", category="Japanese Scales", intervals={0, 1, 5, 6, 10}, aliases={}},
  {name="Kumoi", category="Japanese Scales", intervals={0, 2, 3, 7, 9}, aliases={}},
  {name="Yo", category="Japanese Scales", intervals={0, 2, 5, 7, 9}, aliases={"Ritsu", "Ritsu Sen"}},
  {name="Pelog", category="Indonesian Scales", intervals={0, 1, 3, 7, 8}, aliases={}},

  -- Blues and jazz scales.
  {name="Dominant Bebop", category="Bebop", intervals={0, 2, 4, 5, 7, 9, 10, 11}, aliases={"Bebop Dominant"}},
  {name="Major Bebop", category="Bebop", intervals={0, 2, 4, 5, 7, 8, 9, 11}, aliases={}},
  {name="Dorian Bebop", category="Bebop", intervals={0, 2, 3, 4, 5, 7, 9, 10}, aliases={}},
  {name="Minor Bebop", category="Bebop", intervals={0, 2, 3, 5, 7, 8, 9, 10}, aliases={}},
  {name="Bebop Locrian", category="Bebop", intervals={0, 2, 3, 5, 6, 8, 9, 10}, aliases={}},

  -- Symmetric collections.
  {name="Whole Tone", category="Symmetric Scales", intervals={0, 2, 4, 6, 8, 10}, aliases={"Whole-Tone Scale"}},
  {name="Diminished (whole-half)", category="Symmetric Scales", intervals={0, 2, 3, 5, 6, 8, 9, 11}, aliases={"Whole-Half Diminished"}},
  {name="Diminished (half-whole)", category="Symmetric Scales", intervals={0, 1, 3, 4, 6, 7, 9, 10}, aliases={"Half-Whole Diminished"}},
  {name="Augmented Scale", category="Symmetric Scales", intervals={0, 3, 4, 7, 8, 11}, aliases={"Augmented"}},
  {name="Chromatic", category="Symmetric Scales", intervals={0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11}, aliases={}},
  {name="Tritone Scale", category="Symmetric Scales", intervals={0, 1, 4, 6, 7, 10}, aliases={"Prometheus Neapolitan"}},

  -- Additional widely used collections.
  {name="Hungarian Major", category="Other Named Scales", intervals={0, 3, 4, 6, 7, 9, 10}, aliases={}},
  {name="Neapolitan Minor", category="Other Named Scales", intervals={0, 1, 3, 5, 7, 8, 11}, aliases={}},
  {name="Persian", category="Other Named Scales", intervals={0, 1, 4, 5, 6, 8, 11}, aliases={}},
  {name="Enigmatic", category="Other Named Scales", intervals={0, 1, 4, 6, 8, 10, 11}, aliases={}},
  {name="Spanish Eight-Tone", category="Other Named Scales", intervals={0, 1, 3, 4, 5, 6, 8, 10}, aliases={}},
  {name="Prometheus", category="Other Named Scales", intervals={0, 2, 4, 6, 9, 10}, aliases={}},
  {name="Lydian Minor", category="Other Named Scales", intervals={0, 2, 4, 6, 7, 8, 10}, aliases={}},
  {name="Hawaiian", category="Other Named Scales", intervals={0, 2, 3, 5, 7, 9, 10, 11}, aliases={}},
  {name="Major Hexatonic", category="Other Named Scales", intervals={0, 2, 4, 5, 7, 9}, aliases={"Hexatonic Major", "Scottish Hexatonic"}},
  {name="Minor Hexatonic", category="Other Named Scales", intervals={0, 2, 3, 5, 7, 10}, aliases={}},
  {name="Leading Whole Tone", category="Other Named Scales", intervals={0, 2, 4, 6, 8, 10, 11}, aliases={}},
  {name="Six-Tone Augmented", category="Other Named Scales", intervals={0, 1, 4, 5, 8, 9}, aliases={}},
  {name="Marwa Thaat", category="Indian Thaats", intervals={0, 1, 4, 6, 7, 9, 11}, aliases={}},
  {name="Poorvi Thaat", category="Indian Thaats", intervals={0, 1, 4, 6, 7, 8, 11}, aliases={}},
  {name="Todi Thaat", category="Indian Thaats", intervals={0, 1, 3, 6, 7, 8, 11}, aliases={}},
  {name="Minor Pentatonic b5", category="Pentatonic", intervals={0, 3, 5, 6, 10}, aliases={}},
  {name="Major Pentatonic b2", category="Pentatonic", intervals={0, 1, 4, 7, 9}, aliases={}},
  {name="Major Pentatonic b6", category="Pentatonic", intervals={0, 2, 4, 7, 8}, aliases={}},
  {name="Minor Sixth Pentatonic", category="Pentatonic", intervals={0, 3, 5, 7, 9}, aliases={}},
  {name="Harmonic Minor Pentatonic", category="Pentatonic", intervals={0, 3, 5, 7, 11}, aliases={}},
  {name="Minor Pentatonic b6", category="Pentatonic", intervals={0, 3, 5, 8, 10}, aliases={}},
  {name="Major Pentatonic Leading Tone", category="Pentatonic", intervals={0, 2, 4, 7, 11}, aliases={}},
  {name="Blues Heptatonic", category="Blues", intervals={0, 3, 4, 5, 6, 7, 10}, aliases={}},
}


