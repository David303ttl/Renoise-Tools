# ACID gate acceptance

Automated scheduling and mocked cell validation do not establish playback
behavior. Renoise gate checks for the current four-line layout are pending.
Use a disposable song and test both Straight (LPB 16) and Triplet (LPB 12).

1. Generate max-length N=32 Play Once and Repeat phrases. Verify four phrase
   lines per source step and the expected output-policy lengths and loop points.
2. Test isolated NOTE, NOTE-TIE, NOTE-TIE-TIE, fresh NOTE after holds, and
   NOTE/REST seams. Inspect scheduled gate/OFF cells and listen for the expected
   release and next attack.
3. Test cold-to-steady and steady-to-steady Repeat seams, including trailing
   TIE and ending REST. Confirm the exclusive-end sentinel remains empty.
4. Compare the two timing modes at the same tempo. Verify step duration remains
   1/4 beat Straight and 1/3 beat Triplet.
5. Record Renoise build, timing mode, output policy, source, line/loop metadata,
   and observed playback. Keep cell inspection distinct from audio observations.

Renoise host checks have not been performed. Do not treat authored cases,
synthetic analyzer checks, or mocked validation as acoustic acceptance.
