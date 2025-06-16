-- File: MidiIO.lua
-- Handles raw MIDI I/O, decodes to msg and filters or forwards.
local renoise = renoise
local MidiIO = { input_device=nil, output_device=nil, callback=nil }

-- Callback for incoming MIDI data
function MidiIO.on_receive(data)
    local status = data[1]
    local d1     = data[2]
    local d2     = data[3]
    local msg_type = math.floor(status/16)
    local channel  = status % 16

    if msg_type == 11 then  -- Controller Change message (0xB0-0xBF)
        local msg = { type="controller", channel=channel, controller_number=d1, value=d2 }
        local handled = false
        if MidiIO.callback and type(MidiIO.callback) == "function" then
            handled = MidiIO.callback(msg) or false
        end
        -- If not handled by the callback, forward the message to output (MIDI thru)
        if not handled and MidiIO.output_device then
            MidiIO.output_device:send(data)
        end
    elseif MidiIO.output_device then
        -- Forward other MIDI messages directly if output device exists
        MidiIO.output_device:send(data)
    end
end

-- Initializes MIDI input/output devices and sets the receive callback
function MidiIO.init(input_name, output_name, recv_cb)
    MidiIO.shutdown() -- Close existing devices first
    MidiIO.callback = recv_cb

    if input_name and input_name~="None" and input_name~="" then
        MidiIO.input_device = renoise.Midi.create_input_device(input_name, MidiIO.on_receive)
    end
    if output_name and output_name~="None" and output_name~="" then
        MidiIO.output_device = renoise.Midi.create_output_device(output_name)
    end
end

-- Shuts down MIDI devices
function MidiIO.shutdown()
    MidiIO.input_device = nil 
    MidiIO.output_device = nil 
end

-- Sends a MIDI Control Change (CC) message
function MidiIO.send_cc(ch, num, val)
    local status = 0xB0 + ch -- MIDI Status byte for CC (0xB0 for channel 1, 0xB1 for channel 2, etc.)
--    print("Sending CC: Status=" .. status .. ", Num=" .. num .. ", Val=" .. val) -- Debugging output
    if MidiIO.output_device then
        MidiIO.output_device:send({status, num, val})
    end
end

-- Sends a MIDI Non-Registered Parameter Number (NRPN) message
-- (Kept for completeness, though not used in current CC-based logic)
function MidiIO.send_nrpn(ch, msb, lsb, val_msb, val_lsb)
    local status = 0xB0 + ch
    if MidiIO.output_device then
        MidiIO.output_device:send({status, 99, msb})  -- NRPN MSB
        MidiIO.output_device:send({status, 98, lsb})  -- NRPN LSB
        MidiIO.output_device:send({status, 6,  val_msb}) -- Data Entry MSB
        MidiIO.output_device:send({status, 38, val_lsb}) -- Data Entry LSB
    end
end

return MidiIO