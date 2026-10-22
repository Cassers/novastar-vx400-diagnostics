using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using VxUsb;
public sealed class VxUsbFake : IUsbBackend, IUsbIo
{
    public DeviceInfo[] Devices;
    public readonly List<byte[]> Writes = new List<byte[]>();
    public readonly List<int> Timeouts = new List<int>();
    public readonly Queue<byte[]> Reads = new Queue<byte[]>();
    public bool Disposed, ThrowRead, ThrowWrite, ThrowOpen;
    public int OpenCount, EnumerateCount, ReadCount, ShortWriteAt = -1, DelayMs;
    public int ProbeModelId = 0x6211;
    public byte[] ProbeReply;
    private byte[] activeCbw, activeReply;
    public int CorruptTag, CorruptResidue, CorruptStatus;
    public bool StatusRoute, BadSignature, NoReply, Coalesce, Fragment;
    public byte[] Reply;
    public VxUsbFake()
    {
        Devices = new DeviceInfo[] { new DeviceInfo("first", "USB first", 0x0483, 0x5720, null) };
    }
    public DeviceInfo[] Enumerate() { EnumerateCount++; return Devices; }
    public IUsbIo Open(DeviceInfo device, int timeoutMs)
    {
        OpenCount++;
        if(ThrowOpen) { throw new IOException("synthetic access denied"); }
        return this;
    }
    public int Write(byte[] bytes, int timeoutMs)
    {
        Timeouts.Add(timeoutMs); Writes.Add((byte[])bytes.Clone());
        if(DelayMs > 0) { Thread.Sleep(DelayMs); }
        if(ThrowWrite) { throw new IOException("synthetic write fault"); }
        if(Writes.Count == ShortWriteAt) { return bytes.Length - 1; }
        if(bytes.Length == 31 && bytes[0] == 0x55 && bytes[1] == 0x53 && bytes[2] == 0x42 && bytes[3] == 0x43)
        {
            if(bytes[15] == 0xA2) { activeCbw=(byte[])bytes.Clone(); }
            else if(bytes[15] == 0xA3)
            {
                byte[] status = Status(bytes, 2);
                if(Coalesce)
                {
                    byte[] both = new byte[activeReply.Length + status.Length];
                    Array.Copy(activeReply, both, activeReply.Length); Array.Copy(status, 0, both, activeReply.Length, status.Length); Queue(both);
                }
                else { Queue(activeReply); Queue(status); }
            }
        }
        else if(bytes.Length >= 20 && bytes[0] == 0x55 && bytes[1] == 0xAA && !NoReply)
        {
            bool probe=bytes[10]==0 && bytes[12]==2 && bytes[13]==0 && bytes[14]==0 && bytes[15]==0 && bytes[16]==2 && bytes[17]==0;
            activeReply=probe ? (ProbeReply ?? ModelResponse(bytes,ProbeModelId)) : Reply;
            if(StatusRoute) { Queue(Status(activeCbw, 1)); }
            else if(Coalesce)
            {
                byte[] status=Status(activeCbw,1); byte[] both=new byte[activeReply.Length+status.Length];
                Array.Copy(activeReply,both,activeReply.Length); Array.Copy(status,0,both,activeReply.Length,status.Length); Queue(both);
            }
            else { Queue(activeReply); }
        }
        return bytes.Length;
    }
    public static byte[] ModelResponse(byte[] request, int model)
    {
        byte[] reply=new byte[22]; Array.Copy(request,reply,18);
        reply[0]=0xAA; reply[1]=0x55; reply[4]=request[5]; reply[5]=request[4];
        reply[18]=(byte)model; reply[19]=(byte)(model>>8); Rechecksum(reply); return reply;
    }
    public static void Rechecksum(byte[] reply)
    {
        int sum=0x5555; for(int i=2;i<reply.Length-2;i++){sum+=reply[i];}
        reply[reply.Length-2]=(byte)sum; reply[reply.Length-1]=(byte)(sum>>8);
    }
    private byte[] Status(byte[] cbw, int route)
    {
        byte[] status = new byte[13];
        status[0] = 0x55; status[1] = 0x53; status[2] = 0x42; status[3] = 0x53;
        Array.Copy(cbw, 4, status, 4, 4);
        if(CorruptTag == route) { status[4] ^= 1; }
        if(CorruptResidue == route) { status[8] = 1; }
        if(CorruptStatus == route) { status[12] = 1; }
        if(BadSignature) { status[3] = 0x43; }
        return status;
    }
    private void Queue(byte[] bytes)
    {
        if(bytes == null) { return; }
        if(!Fragment) { Reads.Enqueue(bytes); return; }
        for(int i=0; i<bytes.Length; )
        {
            int count = Math.Min(3, bytes.Length-i); byte[] part=new byte[count];
            Array.Copy(bytes,i,part,0,count); Reads.Enqueue(part); i+=count;
        }
    }
    public int Read(byte[] buffer, int timeoutMs)
    {
        Timeouts.Add(timeoutMs); ReadCount++;
        if(DelayMs > 0) { Thread.Sleep(DelayMs); }
        if(ThrowRead) { throw new IOException("synthetic read fault"); }
        if(NoReply) { throw new TimeoutException("synthetic bulk timeout"); }
        if(Reads.Count == 0) { return 0; }
        byte[] bytes=Reads.Dequeue();
        if(bytes.Length > buffer.Length) { return buffer.Length + 1; }
        Array.Copy(bytes,buffer,bytes.Length); return bytes.Length;
    }
    public void Dispose() { Disposed=true; }
}
