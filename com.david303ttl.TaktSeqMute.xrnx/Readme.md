# TaktSeqMute Renoise Tool

## Overview

I wrote this tool to get around one of the limitations when Digitakt is sequenced externally. In this case by Renoise.
Mute only works on the internal sequencer. 
https://www.elektronauts.com/t/mute-track-triggered-by-external-midi/210265

Here if I press Mute - it mutes Amp Volume (can be changed to Track Level), unmute restores the last volume state.

The tool works, consider this the first version, as it has some features I will probably still work on:
- This version operates on MIDI CC - making the encoder resolution 0-127. 
I will be working on the NRPN version. First I needed to check the functionality.
- Initial state 
StateManager.state[ch] = { last_level=100, is_muted=false }
If after starting the tool, on Digitakt audio ch is muted, you need to do mute/unmute until the state of the tool is the same as hardware. Then it works decently. Same as move the encoder for Amp Level.

I use Overbridge for audio and usb midi. 
Each audio track has a counterpart as a track in Renoise. Each audio track is assigned a separate midi channel on the hardware and the same in Renoise. And this is very important. Because the controls are the same for each audio channel and if you don't assign this well there will be surprises like:
changing the loop on audio 3, will modify the grid on audio 5 :) I warned you.
  
To set it up easily I use the revised Midi Management Console.
https://forum.renoise.com/t/new-tool-2-8-midi-management-console/35513/29

Now you can play and jam. Digitakt mutes the track, without bothering to turn off the external sequencer. I also think it will be helpful to use ‘Digitakt Scenes Hack’. No additional controllers, midi hubs. Renoise and Digitakt.
https://www.elektronauts.com/t/digitakt-scenes-hack-using-external-sequencer/148528

The tool should work for: DT, DN, ST, A4. 
M:C and M:S may require a midi CC change. AR has level controls differently written in the midi implementation. 
Editing Config.lua is trivial and I tried to give comments plus it's easy to check everything in the official Elektron manuals. 
I would need some feedback if at all anyone is going to use this tool other than me. I might have missed something, somewhere some bug might still be hiding (and will attack surprisingly).
Use at your own risk, I do not take responsibility for anything.


## Usage

1.  **Open TaktSeqMute Settings:** In Renoise, go to `Instrument Box` -> `TaktSeqMute Settings...`.
2.  **Select MIDI Devices:** Choose your MIDI input device and MIDI output device.
3.  **Restart Listener:** Click "Restart Listener" to apply the MIDI device changes.
4.  **Trigger Mute:** Press the configured mute button on your MIDI controller. The corresponding track's volume in Digitakt should now toggle between 0 and its last known level.
5.  **Adjust Level:** Turning level encoder it will directly adjust the track volume, and the tool will remember this level for subsequent unmuting operations.




