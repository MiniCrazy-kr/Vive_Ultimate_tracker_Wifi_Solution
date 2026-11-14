using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public static class UtkUsbReset
{
    [StructLayout(LayoutKind.Sequential)]
    private struct InterfaceData
    {
        public int Size;
        public Guid ClassGuid;
        public int Flags;
        public IntPtr Reserved;
    }

    [DllImport("hid.dll")] private static extern void HidD_GetHidGuid(out Guid guid);
    [DllImport("hid.dll")]
    [return: MarshalAs(UnmanagedType.U1)]
    private static extern bool HidD_GetSerialNumberString(SafeFileHandle handle, byte[] serial, int length);
    [DllImport("hid.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.U1)]
    private static extern bool HidD_SetFeature(SafeFileHandle handle, byte[] report, int length);
    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr SetupDiGetClassDevs(ref Guid guid, string enumerator, IntPtr window, int flags);
    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiEnumDeviceInterfaces(IntPtr set, IntPtr device, ref Guid guid, int index, ref InterfaceData data);
    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr set, ref InterfaceData data, IntPtr detail, int length, out int required, IntPtr device);
    [DllImport("setupapi.dll")] private static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(string path, uint access, int share, IntPtr security, int disposition, int flags, IntPtr template);

    private static bool HasSerial(SafeFileHandle handle, string serial)
    {
        if (handle.IsInvalid) return false;
        byte[] buffer = new byte[256];
        return HidD_GetSerialNumberString(handle, buffer, buffer.Length)
            && String.Equals(Encoding.Unicode.GetString(buffer).TrimEnd('\0'), serial, StringComparison.OrdinalIgnoreCase);
    }

    private static List<string> Find(string serial)
    {
        var paths = new List<string>();
        Guid guid;
        HidD_GetHidGuid(out guid);
        IntPtr set = SetupDiGetClassDevs(ref guid, null, IntPtr.Zero, 0x12);
        if (set == new IntPtr(-1)) throw new Win32Exception();
        try
        {
            for (int i = 0; ; i++)
            {
                var entry = new InterfaceData { Size = Marshal.SizeOf(typeof(InterfaceData)) };
                if (!SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref guid, i, ref entry))
                {
                    if (Marshal.GetLastWin32Error() == 259) break;
                    throw new Win32Exception();
                }
                int size;
                SetupDiGetDeviceInterfaceDetail(set, ref entry, IntPtr.Zero, 0, out size, IntPtr.Zero);
                if (size <= 8) continue;
                IntPtr detail = Marshal.AllocHGlobal(size);
                try
                {
                    Marshal.WriteInt32(detail, IntPtr.Size == 8 ? 8 : 6);
                    if (!SetupDiGetDeviceInterfaceDetail(set, ref entry, detail, size, out size, IntPtr.Zero)) continue;
                    string path = Marshal.PtrToStringUni(IntPtr.Add(detail, 4));
                    if (!path.StartsWith(@"\\?\hid#vid_0bb4&pid_06a3&mi_00", StringComparison.OrdinalIgnoreCase)) continue;
                    using (var handle = CreateFile(path, 0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero))
                        if (HasSerial(handle, serial)) paths.Add(path);
                }
                finally { Marshal.FreeHGlobal(detail); }
            }
        }
        finally { SetupDiDestroyDeviceInfoList(set); }
        return paths;
    }

    public static void Reset(string serial)
    {
        if (String.IsNullOrWhiteSpace(serial)) throw new ArgumentException("Select a tracker with a serial number.");
        var paths = Find(serial);
        if (paths.Count != 1)
            throw new InvalidOperationException("Connect exactly one matching tracker by USB and retry.");
        using (var handle = CreateFile(paths[0], 0x40000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero))
        {
            if (handle.IsInvalid) throw new Win32Exception();
            if (!HasSerial(handle, serial)) throw new InvalidOperationException("The USB tracker changed.");
            byte[] report = new byte[65];
            report[1] = 0xFF;
            report[2] = 0xAF;
            if (!HidD_SetFeature(handle, report, report.Length)) throw new Win32Exception();
        }
    }
}
