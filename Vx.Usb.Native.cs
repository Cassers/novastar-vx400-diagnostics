// Clean-room NovaStar UDiskMode transport. No vendor binaries or driver replacement.
// libusb0 ABI: libusb-win32 lusb0_usb.h (Pack=1, LIBUSB_PATH_MAX=512).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

namespace VxUsb
{
    public sealed class DeviceInfo
    {
        public string Key { get; private set; }
        public string DisplayName { get; private set; }
        public ushort Vid { get; private set; }
        public ushort Pid { get; private set; }
        public string Serial { get; private set; }
        internal IntPtr NativeDevice;
        internal byte InputEndpoint, OutputEndpoint;
        public DeviceInfo(string key, string displayName, ushort vid, ushort pid, string serial)
        { Key = key; DisplayName = displayName; Vid = vid; Pid = pid; Serial = serial; }
    }

    // Production driver and tests share this state machine; fakes never load a DLL.
    public interface IUsbIo : IDisposable
    {
        int Write(byte[] bytes, int timeoutMs);
        int Read(byte[] buffer, int timeoutMs);
    }
    public interface IUsbBackend
    {
        DeviceInfo[] Enumerate();
        IUsbIo Open(DeviceInfo device, int timeoutMs);
    }

    public static class Transport
    {
        private static long nextTag = InitialTag();
        private static long InitialTag()
        {
            byte[] bytes = new byte[4];
            using (RandomNumberGenerator random = RandomNumberGenerator.Create()) { random.GetBytes(bytes); }
            return (long)BitConverter.ToUInt32(bytes, 0);
        }
        private static uint NextTag() { return unchecked((uint)Interlocked.Increment(ref nextTag)); }
        internal static int Remaining(Stopwatch watch, int timeoutMs)
        {
            long remaining = timeoutMs - watch.ElapsedMilliseconds;
            if (remaining <= 0) { throw new TimeoutException("USB transaction deadline expired."); }
            return (int)remaining;
        }
        public static DeviceInfo Select(DeviceInfo[] devices, string key)
        {
            if (devices == null) { throw new IOException("USB enumeration returned no device list."); }
            DeviceInfo selected = null;
            HashSet<string> keys = new HashSet<string>(StringComparer.Ordinal);
            foreach (DeviceInfo device in devices)
            {
                if (device == null || String.IsNullOrEmpty(device.Key) || !keys.Add(device.Key))
                    { throw new IOException("USB discovery returned an invalid or duplicate selector; reconnect devices and refresh."); }
                if (String.Equals(device.Key, key, StringComparison.Ordinal)) { selected = device; }
            }
            if (String.IsNullOrEmpty(key))
            {
                if (devices.Length == 0) { throw new IOException("No compatible NovaStar USB device found through the installed libusb0 driver (0483:5720)."); }
                if (devices.Length != 1) { throw new IOException("Multiple compatible USB devices found. Select an explicit USB device before sending commands."); }
                return devices[0];
            }
            if (selected == null) { throw new IOException("Selected USB device is missing. Refresh USB devices and select the connected controller."); }
            return selected;
        }
        public static int ExpectedReplyLength(byte[] request)
        {
            if (request == null || request.Length < 20 || request.Length > 4116 || request[0] != 0x55 || request[1] != 0xAA)
                { throw new ArgumentException("USB requires a complete canonical 55 AA register frame.", "request"); }
            int length = request[16] | (request[17] << 8);
            if (length < 1 || length > 4096 || (request[10] != 0 && request[10] != 1) ||
                (request[10] == 0 && request.Length != 20) || (request[10] == 1 && request.Length != 20 + length))
                { throw new ArgumentException("Invalid USB register frame command or length.", "request"); }
            return request[10] == 1 ? 20 : 20 + length;
        }
        public static byte[] CommandBlock(uint tag, int payloadLength, bool input)
        {
            if (payloadLength < 1 || payloadLength > 4116) { throw new ArgumentOutOfRangeException("payloadLength"); }
            byte[] block = new byte[31];
            block[0] = 0x55; block[1] = 0x53; block[2] = 0x42; block[3] = 0x43;
            PutUInt32(block, 4, tag); PutUInt32(block, 8, (uint)payloadLength);
            block[12] = input ? (byte)0x80 : (byte)0; block[14] = 0x10;
            block[15] = input ? (byte)0xA3 : (byte)0xA2; block[22] = 1;
            return block;
        }
        private static void PutUInt32(byte[] target, int offset, uint value)
        {
            for (int i = 0; i < 4; i++) { target[offset + i] = (byte)(value >> (8 * i)); }
        }
        private static uint UInt32At(byte[] bytes, int offset)
        {
            return (uint)(bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24));
        }
        private static void Write(IUsbIo io, byte[] bytes, Stopwatch watch, int timeoutMs)
        {
            int written = io.Write(bytes, Remaining(watch, timeoutMs));
            Remaining(watch, timeoutMs);
            // Retrying the remainder could turn one CBW/payload into a different USB command.
            if (written != bytes.Length) { throw new IOException("USB short write; transaction aborted without retrying a partial command."); }
        }
        private static void ValidateStatus(byte[] status, uint expectedTag)
        {
            if (status.Length != 13 || status[0] != 0x55 || status[1] != 0x53 || status[2] != 0x42 || status[3] != 0x53)
                { throw new InvalidDataException("Invalid USB command status signature (expected USBS)."); }
            if (UInt32At(status, 4) != expectedTag) { throw new InvalidDataException("USB command status tag does not match the submitted command."); }
            if (UInt32At(status, 8) != 0) { throw new InvalidDataException("USB command status reports an incomplete transfer (nonzero residue)."); }
            if (status[12] != 0) { throw new InvalidDataException("USB command failed or entered a phase error (status " + status[12] + ")."); }
        }
        private sealed class Reader
        {
            private readonly IUsbIo io;
            private readonly Stopwatch watch;
            private readonly int timeoutMs;
            private readonly List<byte> pending = new List<byte>();
            public Reader(IUsbIo io, Stopwatch watch, int timeoutMs) { this.io = io; this.watch = watch; this.timeoutMs = timeoutMs; }
            public byte[] Take(int count)
            {
                while (pending.Count < count)
                {
                    // Read a full packet-sized buffer, even when only a status prefix is needed.
                    byte[] packet = new byte[8192];
                    int got = io.Read(packet, Remaining(watch, timeoutMs));
                    Remaining(watch, timeoutMs);
                    if (got <= 0 || got > packet.Length) { throw new IOException("USB returned an empty or invalid bulk read before the complete response."); }
                    if (pending.Count + got > 8256) { throw new InvalidDataException("USB response exceeds the bounded register/status buffer."); }
                    for (int i = 0; i < got; i++) { pending.Add(packet[i]); }
                }
                byte[] result = pending.GetRange(0, count).ToArray(); pending.RemoveRange(0, count);
                return result;
            }
            public int Pending { get { return pending.Count; } }
        }
        internal static void ValidateWriteModel(byte[] request, int expectedModelId)
        {
            if (request[10] == 1 && expectedModelId != 0x6211 && expectedModelId != 0x620E)
                { throw new ArgumentException("USB writes require ExpectedModelId 0x6211 (VX400) or 0x620E (VX600).", "expectedModelId"); }
        }
        private static ushort Checksum(byte[] frame)
        {
            int sum = 0x5555;
            for (int i = 2; i < frame.Length - 2; i++) { sum += frame[i]; }
            return (ushort)(sum & 0xFFFF);
        }
        private static byte[] ModelProbe(byte sequence)
        {
            byte[] frame = new byte[20];
            frame[0] = 0x55; frame[1] = 0xAA; frame[3] = sequence; frame[4] = 0xFE;
            frame[12] = 2; frame[16] = 2;
            ushort checksum = Checksum(frame); frame[18] = (byte)checksum; frame[19] = (byte)(checksum >> 8);
            return frame;
        }
        private static void ValidateModelProbe(byte[] reply, byte[] probe, int expectedModelId)
        {
            if (reply.Length != 22 || reply[0] != 0xAA || reply[1] != 0x55 || reply[2] != 0 ||
                reply[3] != probe[3] || reply[4] != probe[5] || reply[5] != probe[4] || reply[16] != 2 || reply[17] != 0)
                { throw new InvalidDataException("USB ModelID probe header, status, routing, sequence or payload length is invalid; write blocked."); }
            for (int i = 6; i <= 15; i++)
            {
                if (reply[i] != probe[i]) { throw new InvalidDataException("USB ModelID probe correlation is invalid; write blocked."); }
            }
            if ((reply[20] | (reply[21] << 8)) != Checksum(reply))
                { throw new InvalidDataException("USB ModelID probe checksum is invalid; write blocked."); }
            int actualModelId = reply[18] | (reply[19] << 8);
            if (actualModelId != expectedModelId)
                { throw new InvalidDataException("USB ModelID mismatch on the opened handle: expected 0x" + expectedModelId.ToString("X4") + ", received 0x" + actualModelId.ToString("X4") + "; write blocked."); }
        }
        public static byte[] Exchange(IUsbBackend backend, byte[] request, int timeoutMs, string deviceKey, int expectedModelId = 0)
        {
            if (backend == null) { throw new ArgumentNullException("backend"); }
            if (timeoutMs < 1 || timeoutMs > 15000) { throw new ArgumentOutOfRangeException("timeoutMs"); }
            int replyLength = ExpectedReplyLength(request);
            request = (byte[])request.Clone();
            ValidateWriteModel(request, expectedModelId);
            Stopwatch watch = Stopwatch.StartNew();
            DeviceInfo device = Select(backend.Enumerate(), deviceKey);
            IUsbIo io = backend.Open(device, Remaining(watch, timeoutMs));
            if (io == null) { throw new IOException("USB driver returned no device handle."); }
            using (io)
            {
                if (request[10] == 1)
                {
                    // A cached discovery/ModelID result cannot authorize a new opened USB handle.
                    // Probe and mutation stay on this one handle and consume one shared deadline.
                    byte[] probe = ModelProbe((byte)(request[3] ^ 0x80));
                    byte[] identity = ExchangeOnIo(io, probe, 22, watch, timeoutMs);
                    ValidateModelProbe(identity, probe, expectedModelId);
                    Remaining(watch, timeoutMs);
                }
                return ExchangeOnIo(io, request, replyLength, watch, timeoutMs);
            }
        }
        private static byte[] ExchangeOnIo(IUsbIo io, byte[] request, int replyLength, Stopwatch watch, int timeoutMs)
        {
            uint writeTag = NextTag();
            Write(io, CommandBlock(writeTag, request.Length, false), watch, timeoutMs);
            Write(io, request, watch, timeoutMs);
            if (request.Length % 64 == 0) { Write(io, new byte[0], watch, timeoutMs); }
            Reader reader = new Reader(io, watch, timeoutMs);
            byte[] prefix = reader.Take(2);
            if (prefix[0] == 0xAA && prefix[1] == 0x55)
            {
                byte[] reply = new byte[replyLength]; Array.Copy(prefix, reply, 2);
                Array.Copy(reader.Take(replyLength - 2), 0, reply, 2, replyLength - 2);
                // Some firmwares may coalesce a normal write CSW after a direct reply.
                // Do not wait for an unobserved CSW: the published vendor path returns directly.
                if (reader.Pending != 0)
                {
                    if (reader.Pending > 13) { throw new InvalidDataException("Excess trailing data after the direct USB response."); }
                    ValidateStatus(reader.Take(13), writeTag);
                    if (reader.Pending != 0) { throw new InvalidDataException("Unexpected trailing data after direct USB command status."); }
                }
                return reply; // Protocol module verifies checksum, routing, sequence and payload.
            }
            byte[] status = new byte[13]; Array.Copy(prefix, status, 2);
            Array.Copy(reader.Take(11), 0, status, 2, 11); ValidateStatus(status, writeTag);
            if (reader.Pending != 0) { throw new InvalidDataException("Unexpected data after USB write command status."); }
            uint readTag = NextTag();
            Write(io, CommandBlock(readTag, replyLength, true), watch, timeoutMs);
            byte[] response = reader.Take(replyLength);
            ValidateStatus(reader.Take(13), readTag);
            if (reader.Pending != 0) { throw new InvalidDataException("Unexpected trailing data after USB read command status."); }
            if (response[0] != 0xAA || response[1] != 0x55) { throw new InvalidDataException("USB read returned an invalid NovaStar response header."); }
            return response;
        }
    }

    // Native structs mirror the public libusb-win32 C ABI, never guessed offsets.
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public struct UsbDeviceDescriptor
    {
        public byte Length, DescriptorType;
        public ushort UsbVersion;
        public byte DeviceClass, DeviceSubClass, DeviceProtocol, MaxPacketSize0;
        public ushort VendorId, ProductId, DeviceVersion;
        public byte Manufacturer, Product, SerialNumber, ConfigurationCount;
    }
    [StructLayout(LayoutKind.Sequential, Pack = 1, CharSet = CharSet.Ansi)]
    public struct UsbDevice
    {
        public IntPtr Next, Previous;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 512)] public string Filename;
        public IntPtr Bus;
        public UsbDeviceDescriptor Descriptor;
        public IntPtr Config, Dev;
        public byte DeviceNumber, ChildCount;
        public IntPtr Children;
    }
    [StructLayout(LayoutKind.Sequential, Pack = 1, CharSet = CharSet.Ansi)]
    public struct UsbBus
    {
        public IntPtr Next, Previous;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 512)] public string Directory;
        public IntPtr Devices;
        public uint Location; // C unsigned long is 32 bits on Windows, including x64.
        public IntPtr RootDevice;
    }
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public struct UsbConfig
    {
        public byte Length, DescriptorType;
        public ushort TotalLength;
        public byte InterfaceCount, ConfigurationValue, ConfigurationString, Attributes, MaxPower;
        public IntPtr Interfaces, Extra;
        public int ExtraLength;
    }
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public struct UsbInterface { public IntPtr AlternateSettings; public int AlternateCount; }
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public struct UsbInterfaceDescriptor
    {
        public byte Length, DescriptorType, InterfaceNumber, AlternateSetting, EndpointCount, InterfaceClass, SubClass, Protocol, InterfaceString;
        public IntPtr Endpoints, Extra;
        public int ExtraLength;
    }
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public struct UsbEndpoint
    {
        public byte Length, DescriptorType, Address, Attributes;
        public ushort MaxPacketSize;
        public byte Interval, Refresh, SynchAddress;
        public IntPtr Extra;
        public int ExtraLength;
    }

    internal sealed class NativeApi
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr LoadLibraryEx(string filename, IntPtr file, uint flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Ansi, ExactSpelling = true, SetLastError = true)]
        private static extern IntPtr GetProcAddress(IntPtr module, string name);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate void InitFn();
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate int FindFn();
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate IntPtr BussesFn();
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate IntPtr OpenFn(IntPtr device);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate int CloseFn(IntPtr handle);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate int ConfigFn(IntPtr handle, int number);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate int BulkFn(IntPtr handle, int endpoint, [In, Out] byte[] buffer, int size, int timeoutMs);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate int StringFn(IntPtr handle, int index, [Out] byte[] buffer, UIntPtr length);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate IntPtr ErrorFn();
        private readonly IntPtr module;
        internal readonly FindFn FindBusses, FindDevices;
        internal readonly BussesFn GetBusses;
        internal readonly OpenFn Open;
        internal readonly CloseFn Close;
        internal readonly ConfigFn Configure, Claim, Release;
        internal readonly BulkFn BulkWrite, BulkRead;
        internal readonly StringFn GetString;
        internal readonly ErrorFn GetError;
        internal static readonly Lazy<NativeApi> Instance = new Lazy<NativeApi>(delegate { return new NativeApi(); });
        private T Function<T>(string name, bool optional) where T : class
        {
            IntPtr address = GetProcAddress(module, name);
            if (address == IntPtr.Zero)
            {
                if (optional) { return null; }
                throw new IOException("Installed libusb0.dll does not export " + name + ". Repair the original NovaStar USB driver installation.");
            }
            return (T)(object)Marshal.GetDelegateForFunctionPointer(address, typeof(T));
        }
        private NativeApi()
        {
            if (Environment.OSVersion.Platform != PlatformID.Win32NT) { throw new PlatformNotSupportedException("Native NovaStar USB requires Windows and the existing NovaStar libusb0 driver."); }
            string path = Path.Combine(Environment.SystemDirectory, "libusb0.dll");
            if (!File.Exists(path)) { throw new FileNotFoundException("The installed NovaStar libusb0.dll is missing from the Windows system directory. Install/repair the original NovaStar driver; this application never replaces drivers.", path); }
            // Absolute path and constrained dependency search prevent CWD/application DLL hijacking.
            module = LoadLibraryEx(path, IntPtr.Zero, 0x00000100 | 0x00000800);
            if (module == IntPtr.Zero) { throw new IOException("Cannot load system libusb0.dll for this PowerShell architecture (Win32 error " + Marshal.GetLastWin32Error() + "). Use the installed driver's matching x86/x64 architecture."); }
            InitFn init = Function<InitFn>("usb_init", false);
            FindBusses = Function<FindFn>("usb_find_busses", false); FindDevices = Function<FindFn>("usb_find_devices", false);
            GetBusses = Function<BussesFn>("usb_get_busses", false); Open = Function<OpenFn>("usb_open", false);
            Close = Function<CloseFn>("usb_close", false); Configure = Function<ConfigFn>("usb_set_configuration", false);
            Claim = Function<ConfigFn>("usb_claim_interface", false); Release = Function<ConfigFn>("usb_release_interface", false);
            BulkWrite = Function<BulkFn>("usb_bulk_write", false); BulkRead = Function<BulkFn>("usb_bulk_read", false);
            GetString = Function<StringFn>("usb_get_string_simple", true); GetError = Function<ErrorFn>("usb_strerror", true);
            init();
        }
        internal Exception Failure(string operation, int code)
        {
            if (code == -116 || code == -110) { return new TimeoutException("USB " + operation + " timed out (libusb0 " + code + ")."); }
            string detail = GetError == null ? "" : Marshal.PtrToStringAnsi(GetError());
            return new IOException("USB " + operation + " failed (libusb0 " + code + "). " + detail + " Close other controller applications and check the original driver/device access.");
        }
    }

    internal sealed class NativeBackend : IUsbBackend
    {
        private readonly NativeApi api;
        private readonly bool readSerial;
        internal NativeBackend(bool readSerial) { api = NativeApi.Instance.Value; this.readSerial = readSerial; }
        private static T Read<T>(IntPtr pointer)
        {
            if (pointer == IntPtr.Zero) { throw new IOException("USB driver returned an invalid descriptor pointer."); }
            return (T)Marshal.PtrToStructure(pointer, typeof(T));
        }
        private static IntPtr At<T>(IntPtr pointer, int index) { return IntPtr.Add(pointer, checked(Marshal.SizeOf(typeof(T)) * index)); }
        private static bool Endpoints(UsbDevice device, out byte input, out byte output)
        {
            input = 0; output = 0;
            if (device.Descriptor.ConfigurationCount < 1 || device.Descriptor.ConfigurationCount > 8 || device.Config == IntPtr.Zero) { return false; }
            for (int c = 0; c < device.Descriptor.ConfigurationCount; c++)
            {
                UsbConfig config = Read<UsbConfig>(At<UsbConfig>(device.Config, c));
                if (config.Length < 9 || config.DescriptorType != 2 || config.ConfigurationValue != 1 || config.InterfaceCount > 32 || config.Interfaces == IntPtr.Zero) { continue; }
                for (int i = 0; i < config.InterfaceCount; i++)
                {
                    UsbInterface iface = Read<UsbInterface>(At<UsbInterface>(config.Interfaces, i));
                    if (iface.AlternateCount < 1 || iface.AlternateCount > 128 || iface.AlternateSettings == IntPtr.Zero) { continue; }
                    for (int a = 0; a < iface.AlternateCount; a++)
                    {
                        UsbInterfaceDescriptor descriptor = Read<UsbInterfaceDescriptor>(At<UsbInterfaceDescriptor>(iface.AlternateSettings, a));
                        if (descriptor.Length < 9 || descriptor.DescriptorType != 4 || descriptor.InterfaceNumber != 0 || descriptor.AlternateSetting != 0 ||
                            descriptor.InterfaceClass != 0xFF || descriptor.SubClass != 0x06 || descriptor.Protocol != 0x50 || descriptor.EndpointCount > 32 || descriptor.Endpoints == IntPtr.Zero) { continue; }
                        byte foundIn = 0, foundOut = 0;
                        bool duplicate = false;
                        for (int e = 0; e < descriptor.EndpointCount; e++)
                        {
                            UsbEndpoint endpoint = Read<UsbEndpoint>(At<UsbEndpoint>(descriptor.Endpoints, e));
                            if (endpoint.Length < 7 || endpoint.DescriptorType != 5 || (endpoint.Attributes & 3) != 2 || (endpoint.Address & 15) == 0 || (endpoint.Address & 0x70) != 0 || endpoint.MaxPacketSize == 0) { continue; }
                            if ((endpoint.Address & 0x80) != 0) { if (foundIn != 0) { duplicate = true; } foundIn = endpoint.Address; }
                            else { if (foundOut != 0) { duplicate = true; } foundOut = endpoint.Address; }
                        }
                        if (!duplicate && foundIn != 0 && foundOut != 0) { input = foundIn; output = foundOut; return true; }
                    }
                }
            }
            return false;
        }
        public DeviceInfo[] Enumerate()
        {
            int result = api.FindBusses(); if (result < 0) { throw api.Failure("bus discovery", result); }
            result = api.FindDevices(); if (result < 0) { throw api.Failure("device discovery", result); }
            List<DeviceInfo> devices = new List<DeviceInfo>();
            HashSet<IntPtr> busses = new HashSet<IntPtr>(); HashSet<IntPtr> pointers = new HashSet<IntPtr>();
            bool unsupported = false;
            for (IntPtr busPointer = api.GetBusses(); busPointer != IntPtr.Zero; )
            {
                if (!busses.Add(busPointer) || busses.Count > 128) { throw new IOException("USB driver returned a cyclic or excessive bus list."); }
                UsbBus bus = Read<UsbBus>(busPointer);
                for (IntPtr pointer = bus.Devices; pointer != IntPtr.Zero; )
                {
                    if (!pointers.Add(pointer) || pointers.Count > 1024) { throw new IOException("USB driver returned a cyclic or excessive device list."); }
                    IntPtr devicePointer = pointer;
                    UsbDevice device = Read<UsbDevice>(devicePointer); pointer = device.Next;
                    if (device.Descriptor.VendorId != 0x0483 || device.Descriptor.ProductId != 0x5720) { continue; }
                    byte input, output;
                    if (device.Descriptor.Length < 18 || device.Descriptor.DescriptorType != 1 || !Endpoints(device, out input, out output)) { unsupported = true; continue; }
                    if (String.IsNullOrEmpty(device.Filename)) { throw new IOException("NovaStar USB device has no stable driver filename selector."); }
                    string key;
                    using (SHA256 hash = SHA256.Create()) { key = "libusb0:0483:5720:" + BitConverter.ToString(hash.ComputeHash(Encoding.UTF8.GetBytes(device.Filename.ToLowerInvariant()))).Replace("-", "").ToLowerInvariant(); }
                    string serial = null;
                    if (readSerial && api.GetString != null && device.Descriptor.SerialNumber != 0)
                    {
                        IntPtr handle = api.Open(devicePointer);
                        if (handle != IntPtr.Zero)
                        {
                            try
                            {
                                byte[] text = new byte[256];
                                int count = api.GetString(handle, device.Descriptor.SerialNumber, text, new UIntPtr((uint)text.Length));
                                if (count > 0 && count <= text.Length) { serial = Encoding.UTF8.GetString(text, 0, count).TrimEnd('\0'); }
                            }
                            finally { api.Close(handle); }
                        }
                    }
                    string label = String.IsNullOrEmpty(serial) ? device.Filename : serial;
                    DeviceInfo info = new DeviceInfo(key, "NovaStar USB 0483:5720 (" + label + ")", 0x0483, 0x5720, serial);
                    info.NativeDevice = devicePointer; info.InputEndpoint = input; info.OutputEndpoint = output;
                    devices.Add(info);
                }
                busPointer = bus.Next;
            }
            if (devices.Count == 0 && unsupported) { throw new NotSupportedException("NovaStar USB 0483:5720 is present but configuration 1/interface 0 has no supported FF/06/50 bulk IN/OUT interface."); }
            return devices.ToArray();
        }
        public IUsbIo Open(DeviceInfo device, int timeoutMs) { return new NativeIo(api, device, timeoutMs); }
    }

    internal sealed class NativeIo : IUsbIo
    {
        private readonly NativeApi api;
        private readonly byte input, output;
        private IntPtr handle;
        private bool claimed;
        internal NativeIo(NativeApi api, DeviceInfo device, int timeoutMs)
        {
            this.api = api; input = device.InputEndpoint; output = device.OutputEndpoint;
            Stopwatch watch = Stopwatch.StartNew();
            handle = api.Open(device.NativeDevice);
            if (handle == IntPtr.Zero) { throw api.Failure("open/access", -1); }
            try
            {
                Transport.Remaining(watch, timeoutMs);
                int result = api.Configure(handle, 1); if (result < 0) { throw api.Failure("configuration 1", result); }
                Transport.Remaining(watch, timeoutMs);
                result = api.Claim(handle, 0); if (result < 0) { throw api.Failure("claim interface 0/access", result); }
                claimed = true; Transport.Remaining(watch, timeoutMs);
            }
            catch { Dispose(); throw; }
        }
        public int Write(byte[] bytes, int timeoutMs)
        {
            int result = api.BulkWrite(handle, output, bytes, bytes.Length, timeoutMs);
            if (result < 0) { throw api.Failure("bulk OUT", result); } return result;
        }
        public int Read(byte[] buffer, int timeoutMs)
        {
            int result = api.BulkRead(handle, input, buffer, buffer.Length, timeoutMs);
            if (result < 0) { throw api.Failure("bulk IN", result); } return result;
        }
        public void Dispose()
        {
            if (handle == IntPtr.Zero) { return; }
            try { if (claimed) { api.Release(handle, 0); } }
            finally { api.Close(handle); handle = IntPtr.Zero; claimed = false; }
        }
    }

    public static class Driver
    {
        private static readonly object Gate = new object();
        public static DeviceInfo[] GetDevices() { lock (Gate) { return new NativeBackend(true).Enumerate(); } }
        public static byte[] Exchange(byte[] request, int timeoutMs, string key, int expectedModelId = 0)
        {
            if (timeoutMs < 1 || timeoutMs > 15000) { throw new ArgumentOutOfRangeException("timeoutMs"); }
            Transport.ExpectedReplyLength(request);
            Transport.ValidateWriteModel(request, expectedModelId);
            Stopwatch watch = Stopwatch.StartNew();
            if (!Monitor.TryEnter(Gate, timeoutMs)) { throw new TimeoutException("USB driver is busy with another local transaction."); }
            try { return Transport.Exchange(new NativeBackend(false), request, Transport.Remaining(watch, timeoutMs), key, expectedModelId); }
            finally { Monitor.Exit(Gate); }
        }
    }
}
