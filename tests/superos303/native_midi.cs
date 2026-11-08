// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

// WinMM capture runs on native callbacks without a window or desktop input.
public sealed class SuperOsMidi : IDisposable
{
    const uint CallbackFunction = 0x30000, InputData = 0x3C3, InputLongData = 0x3C4;
    const uint InputError = 0x3C5, InputLongError = 0x3C6, HeaderDone = 1;
    const int BufferSize = 1024, BufferCount = 4, SendTimeoutMs = 3000;
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct Caps { public ushort manufacturer, product; public uint version;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string name; }
    [StructLayout(LayoutKind.Sequential)]
    struct Header { public IntPtr data; public uint length, recorded; public UIntPtr user;
        public uint flags; public IntPtr next; public UIntPtr reserved; public uint offset;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 8)] public UIntPtr[] padding; }
    delegate void Callback(IntPtr device, uint message, UIntPtr instance, UIntPtr first, UIntPtr second);
    [DllImport("winmm.dll")] static extern uint midiInGetNumDevs();
    [DllImport("winmm.dll")] static extern uint midiOutGetNumDevs();
    [DllImport("winmm.dll", CharSet = CharSet.Unicode)] static extern uint midiInGetDevCapsW(UIntPtr id, out Caps caps, uint size);
    // Output capabilities have fields after the common prefix.
    [DllImport("winmm.dll", CharSet = CharSet.Unicode)] static extern uint midiOutGetDevCapsW(UIntPtr id, IntPtr caps, uint size);
    [DllImport("winmm.dll")] static extern uint midiInOpen(out IntPtr device, uint id, Callback callback, UIntPtr instance, uint flags);
    [DllImport("winmm.dll")] static extern uint midiInPrepareHeader(IntPtr device, IntPtr header, uint size);
    [DllImport("winmm.dll")] static extern uint midiInUnprepareHeader(IntPtr device, IntPtr header, uint size);
    [DllImport("winmm.dll")] static extern uint midiInAddBuffer(IntPtr device, IntPtr header, uint size);
    [DllImport("winmm.dll")] static extern uint midiInStart(IntPtr device);
    [DllImport("winmm.dll")] static extern uint midiInReset(IntPtr device);
    [DllImport("winmm.dll")] static extern uint midiInClose(IntPtr device);
    [DllImport("winmm.dll")] static extern uint midiOutOpen(out IntPtr device, uint id, IntPtr callback, UIntPtr instance, uint flags);
    [DllImport("winmm.dll")] static extern uint midiOutPrepareHeader(IntPtr device, IntPtr header, uint size);
    [DllImport("winmm.dll")] static extern uint midiOutUnprepareHeader(IntPtr device, IntPtr header, uint size);
    [DllImport("winmm.dll")] static extern uint midiOutLongMsg(IntPtr device, IntPtr header, uint size);
    [DllImport("winmm.dll")] static extern uint midiOutShortMsg(IntPtr device, uint message);
    [DllImport("winmm.dll")] static extern uint midiOutReset(IntPtr device);
    [DllImport("winmm.dll")] static extern uint midiOutClose(IntPtr device);
    public sealed class MidiEvent { public string kind; public uint time; public byte[] bytes; }
    public readonly ConcurrentQueue<MidiEvent> Events = new ConcurrentQueue<MidiEvent>();
    readonly Callback callback;
    readonly List<IntPtr> headers = new List<IntPtr>();
    readonly uint headerSize = (uint)Marshal.SizeOf<Header>();
    IntPtr input, output;
    volatile bool closing;
    static void Check(uint result, string operation) {
        if (result != 0) throw new InvalidOperationException(operation + " failed (WinMM " + result + ")");
    }
    public static string[] Inputs() {
        var names = new List<string>();
        for (uint i = 0; i < midiInGetNumDevs(); i++) {
            Caps caps; Check(midiInGetDevCapsW((UIntPtr)i, out caps, (uint)Marshal.SizeOf<Caps>()), "input name"); names.Add(caps.name);
        }
        return names.ToArray();
    }
    public static string[] Outputs() {
        const int OutputCapsSize = 84;
        var names = new List<string>(); var memory = Marshal.AllocHGlobal(OutputCapsSize);
        try { for (uint i = 0; i < midiOutGetNumDevs(); i++) {
            Check(midiOutGetDevCapsW((UIntPtr)i, memory, OutputCapsSize), "output name");
            names.Add(Marshal.PtrToStructure<Caps>(memory).name);
        }} finally { Marshal.FreeHGlobal(memory); }
        return names.ToArray();
    }
    public SuperOsMidi(string inputName, string outputName) {
        callback = Receive;
        int inputId = Array.IndexOf(Inputs(), inputName), outputId = Array.IndexOf(Outputs(), outputName);
        if (inputId < 0 || outputId < 0) throw new ArgumentException("Exact MIDI port name not found");
        try {
            Check(midiInOpen(out input, (uint)inputId, callback, UIntPtr.Zero, CallbackFunction), "open input");
            for (int i = 0; i < BufferCount; i++) {
                var memory = Marshal.AllocHGlobal((int)headerSize);
                var header = new Header { data = Marshal.AllocHGlobal(BufferSize), length = BufferSize, padding = new UIntPtr[8] };
                Marshal.StructureToPtr(header, memory, false); headers.Add(memory);
                Check(midiInPrepareHeader(input, memory, headerSize), "prepare input");
                Check(midiInAddBuffer(input, memory, headerSize), "queue input");
            }
            Check(midiOutOpen(out output, (uint)outputId, IntPtr.Zero, UIntPtr.Zero, 0), "open output");
            Check(midiInStart(input), "start input");
        } catch { Dispose(); throw; }
    }
    void Receive(IntPtr device, uint message, UIntPtr instance, UIntPtr first, UIntPtr second) {
        if (closing) return;
        if (message == InputData || message == InputError) {
            uint packed = (uint)first.ToUInt64(); byte status = (byte)packed;
            int count = status >= 0xF8 ? 1 : ((status & 0xE0) == 0xC0 ? 2 : 3);
            var bytes = new byte[count]; for (int i = 0; i < count; i++) bytes[i] = (byte)(packed >> (i * 8));
            Events.Enqueue(new MidiEvent { kind = message == InputError ? "error" : "short", time = (uint)second.ToUInt64(), bytes = bytes });
        } else if (message == InputLongData || message == InputLongError) {
            var memory = (IntPtr)first; var header = Marshal.PtrToStructure<Header>(memory);
            var bytes = new byte[header.recorded]; Marshal.Copy(header.data, bytes, 0, bytes.Length);
            Events.Enqueue(new MidiEvent { kind = message == InputLongError ? "error" : "sysex", time = (uint)second.ToUInt64(), bytes = bytes });
            if (!closing) midiInAddBuffer(input, memory, headerSize);
        }
    }
    public void SendRealtime(byte status) {
        if (status < 0xF8) throw new ArgumentException("Expected a MIDI realtime status");
        Check(midiOutShortMsg(output, status), "send realtime");
    }
    public void Send(byte[] bytes) {
        var data = Marshal.AllocHGlobal(bytes.Length); var memory = Marshal.AllocHGlobal((int)headerSize);
        try {
            Marshal.Copy(bytes, 0, data, bytes.Length);
            Marshal.StructureToPtr(new Header { data = data, length = (uint)bytes.Length, padding = new UIntPtr[8] }, memory, false);
            Check(midiOutPrepareHeader(output, memory, headerSize), "prepare output");
            try {
                Check(midiOutLongMsg(output, memory, headerSize), "send SysEx");
                var deadline = Environment.TickCount64 + SendTimeoutMs;
                while ((Marshal.PtrToStructure<Header>(memory).flags & HeaderDone) == 0) {
                    if (Environment.TickCount64 > deadline) { midiOutReset(output); throw new TimeoutException("MIDI send timed out"); }
                    Thread.Sleep(1);
                }
            } finally { Check(midiOutUnprepareHeader(output, memory, headerSize), "unprepare output"); }
        } finally { Marshal.FreeHGlobal(memory); Marshal.FreeHGlobal(data); }
    }
    public void Dispose() {
        closing = true;
        if (input != IntPtr.Zero) {
            midiInReset(input);
            foreach (var memory in headers) {
                midiInUnprepareHeader(input, memory, headerSize);
                Marshal.FreeHGlobal(Marshal.PtrToStructure<Header>(memory).data); Marshal.FreeHGlobal(memory);
            }
            headers.Clear(); midiInClose(input); input = IntPtr.Zero;
        }
        if (output != IntPtr.Zero) { midiOutClose(output); output = IntPtr.Zero; }
        GC.KeepAlive(callback);
    }
}
