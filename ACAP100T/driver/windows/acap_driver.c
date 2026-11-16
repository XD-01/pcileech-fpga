/*
 * ACAP-100T PCIe video capture driver (Windows KMDF)
 *
 * One MSI vector, four common-buffer frame buffers, and a blocking read
 * interface.  Each ReadFile() returns one complete buffer: the 128-byte ACAP
 * frame header followed by YUYV 4:2:2 data.
 *
 * The INF enables MSI through the standard Interrupt Management registry
 * value.  The driver is a PnP driver and is loaded automatically at boot once
 * it has been signed and installed.
 */
#include <ntddk.h>
#include <wdf.h>
#include <wdfdevice.h>
#include <wdfinterrupt.h>
#include <wdfdmaenabler.h>
#include <wdfcommonbuffer.h>
#include <wdfqueue.h>
#include <wdfrequest.h>
#include <wdfworkitem.h>
#include <wdfspinlock.h>

#include "acap_ioctl_win.h"

#define ACAP_NBUF           4
#define ACAP_TAG            'paca'

typedef struct _ACAP_DEVICE_CONTEXT {
    WDFDEVICE           Device;
    PVOID               Bar;
    PHYSICAL_ADDRESS    BarPhys;
    SIZE_T              BarLength;

    WDFDMAENABLER       DmaEnabler;
    WDFCOMMONBUFFER     CommonBuffer[ACAP_NBUF];
    PVOID               BufVa[ACAP_NBUF];
    PHYSICAL_ADDRESS    BufLa[ACAP_NBUF];

    SIZE_T              FrameBytes;
    SIZE_T              BufStride;
    int                 Nbuf;

    WDFINTERRUPT        Interrupt;
    WDFQUEUE            PendingQueue;
    WDFWORKITEM         WorkItem;
    WDFSPINLOCK         Lock;

    ULONG               DoneShadow;
    BOOLEAN             Started;
    BOOLEAN             QueueStopped;
} ACAP_DEVICE_CONTEXT, *PACAP_DEVICE_CONTEXT;

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(ACAP_DEVICE_CONTEXT, AcapGetContext)

static ULONG AcapReadReg(PACAP_DEVICE_CONTEXT c, ULONG off)
{
    return READ_REGISTER_ULONG((PULONG)((PUCHAR)c->Bar + off));
}

static void AcapWriteReg(PACAP_DEVICE_CONTEXT c, ULONG off, ULONG val)
{
    WRITE_REGISTER_ULONG((PULONG)((PUCHAR)c->Bar + off), val);
}

static BOOLEAN AcapHasDone(PACAP_DEVICE_CONTEXT c)
{
    ULONG done;
    BOOLEAN has;

    WdfSpinLockAcquire(c->Lock);
    done = AcapReadReg(c, ACAP_REG_BUF_DONE) & ~c->DoneShadow;
    has = (done != 0);
    WdfSpinLockRelease(c->Lock);
    return has;
}

static BOOLEAN AcapGetDoneIndex(PACAP_DEVICE_CONTEXT c, ULONG *index)
{
    ULONG done;
    ULONG i;

    WdfSpinLockAcquire(c->Lock);
    done = AcapReadReg(c, ACAP_REG_BUF_DONE) & ~c->DoneShadow;
    if (!done) {
        WdfSpinLockRelease(c->Lock);
        return FALSE;
    }
    for (i = 0; i < ACAP_NBUF; i++) {
        if (done & (1u << i))
            break;
    }
    if (i == ACAP_NBUF) {
        WdfSpinLockRelease(c->Lock);
        return FALSE;
    }
    c->DoneShadow |= (1u << i);
    WdfSpinLockRelease(c->Lock);
    *index = i;
    return TRUE;
}

static void AcapAck(PACAP_DEVICE_CONTEXT c, ULONG index)
{
    AcapWriteReg(c, ACAP_REG_BUF_ACK, 1u << index);

    WdfSpinLockAcquire(c->Lock);
    c->DoneShadow &= ~(1u << index);
    WdfSpinLockRelease(c->Lock);
}

static void AcapCompleteRead(PACAP_DEVICE_CONTEXT c, WDFREQUEST Request)
{
    NTSTATUS status;
    PVOID buffer = NULL;
    size_t length = 0;
    ULONG index = 0;

    status = WdfRequestRetrieveOutputBuffer(Request, c->FrameBytes,
                                            &buffer, &length);
    if (!NT_SUCCESS(status)) {
        WdfRequestComplete(Request, status);
        return;
    }

    if (!AcapGetDoneIndex(c, &index)) {
        WdfRequestComplete(Request, STATUS_UNSUCCESSFUL);
        return;
    }

    KeMemoryBarrier();
    RtlCopyMemory(buffer, c->BufVa[index], c->FrameBytes);
    AcapAck(c, index);
    WdfRequestCompleteWithInformation(Request, STATUS_SUCCESS, c->FrameBytes);
}

static VOID AcapEvtIoRead(WDFQUEUE Queue, WDFREQUEST Request, size_t Length)
{
    PACAP_DEVICE_CONTEXT c = AcapGetContext(WdfIoQueueGetDevice(Queue));
    NTSTATUS status;

    UNREFERENCED_PARAMETER(Length);

    if (!c->Started) {
        WdfRequestComplete(Request, STATUS_INVALID_DEVICE_STATE);
        return;
    }

    if (AcapHasDone(c)) {
        AcapCompleteRead(c, Request);
        return;
    }

    status = WdfRequestForwardToIoQueue(Request, c->PendingQueue);
    if (!NT_SUCCESS(status))
        WdfRequestComplete(Request, status);
}

static VOID AcapEvtWorkItem(WDFWORKITEM WorkItem)
{
    PACAP_DEVICE_CONTEXT c = AcapGetContext(WdfWorkItemGetParentObject(WorkItem));
    WDFREQUEST request;
    NTSTATUS status;

    if (!c->Started)
        return;

    for (;;) {
        if (!AcapHasDone(c))
            break;

        status = WdfIoQueueRetrieveNextRequest(c->PendingQueue, &request);
        if (!NT_SUCCESS(status))
            break;

        AcapCompleteRead(c, request);
    }
}

static VOID AcapStart(PACAP_DEVICE_CONTEXT c)
{
    ULONG ctrl;

    if (c->QueueStopped) {
        WdfIoQueueStart(c->PendingQueue);
        c->QueueStopped = FALSE;
    }

    WdfSpinLockAcquire(c->Lock);
    c->DoneShadow = 0;
    WdfSpinLockRelease(c->Lock);

    ctrl = AcapReadReg(c, ACAP_REG_CONTROL);
    AcapWriteReg(c, ACAP_REG_IRQ_STATUS, 0x7);
    AcapWriteReg(c, ACAP_REG_IRQ_ENABLE,
                 ACAP_IRQ_FRAME_DONE | ACAP_IRQ_FRAME_STALL);
    AcapWriteReg(c, ACAP_REG_CONTROL, ctrl | ACAP_CTRL_ENABLE);
    c->Started = TRUE;
}

static VOID AcapStop(PACAP_DEVICE_CONTEXT c)
{
    c->Started = FALSE;
    AcapWriteReg(c, ACAP_REG_CONTROL, 0);
    AcapWriteReg(c, ACAP_REG_IRQ_ENABLE, 0);

    if (!c->QueueStopped) {
        WdfIoQueuePurgeSynchronously(c->PendingQueue);
        c->QueueStopped = TRUE;
    }
}

static VOID AcapEvtIoDeviceControl(WDFQUEUE Queue, WDFREQUEST Request,
                                   size_t OutputBufferLength,
                                   size_t InputBufferLength,
                                   ULONG IoControlCode)
{
    PACAP_DEVICE_CONTEXT c = AcapGetContext(WdfIoQueueGetDevice(Queue));
    NTSTATUS status = STATUS_SUCCESS;

    UNREFERENCED_PARAMETER(OutputBufferLength);
    UNREFERENCED_PARAMETER(InputBufferLength);

    switch (IoControlCode) {
    case ACAP_IOCTL_GET_INFO: {
        struct acap_info *info = NULL;
        size_t length = 0;

        status = WdfRequestRetrieveOutputBuffer(Request, sizeof(*info),
                                                (PVOID *)&info, &length);
        if (!NT_SUCCESS(status))
            break;

        RtlZeroMemory(info, sizeof(*info));
        info->magic = AcapReadReg(c, ACAP_REG_MAGIC);
        info->version = AcapReadReg(c, ACAP_REG_VERSION);
        info->width = AcapReadReg(c, ACAP_REG_WIDTH);
        info->height = AcapReadReg(c, ACAP_REG_HEIGHT);
        info->stride = AcapReadReg(c, ACAP_REG_STRIDE);
        info->format = AcapReadReg(c, ACAP_REG_FORMAT);
        info->frame_bytes = (acap_u32)c->FrameBytes;
        info->buffer_stride = (acap_u32)c->BufStride;
        info->buffer_count = (acap_u32)c->Nbuf;
        info->caps = AcapReadReg(c, ACAP_REG_CAPS);
        info->pixel_clock_hz = AcapReadReg(c, ACAP_REG_PIXEL_CLK_HZ);
        WdfRequestCompleteWithInformation(Request, STATUS_SUCCESS, sizeof(*info));
        return;
    }

    case ACAP_IOCTL_START:
        AcapStart(c);
        break;

    case ACAP_IOCTL_STOP:
        AcapStop(c);
        break;

    default:
        status = STATUS_INVALID_DEVICE_REQUEST;
        break;
    }

    WdfRequestComplete(Request, status);
}

static BOOLEAN AcapEvtInterruptIsr(WDFINTERRUPT Interrupt, ULONG MessageID)
{
    PACAP_DEVICE_CONTEXT c = AcapGetContext(WdfInterruptGetDevice(Interrupt));
    ULONG status;

    UNREFERENCED_PARAMETER(MessageID);

    status = AcapReadReg(c, ACAP_REG_IRQ_STATUS);
    if (!status)
        return FALSE;

    AcapWriteReg(c, ACAP_REG_IRQ_STATUS, status);
    return TRUE;
}

static VOID AcapEvtInterruptDpc(WDFINTERRUPT Interrupt, WDFOBJECT AssociatedObject)
{
    PACAP_DEVICE_CONTEXT c = AcapGetContext(WdfInterruptGetDevice(Interrupt));

    UNREFERENCED_PARAMETER(AssociatedObject);

    WdfWorkItemEnqueue(c->WorkItem);
}

static NTSTATUS AcapEvtPrepareHardware(WDFDEVICE Device,
                                       WDFCMRESLIST ResourcesRaw,
                                       WDFCMRESLIST ResourcesTranslated)
{
    PACAP_DEVICE_CONTEXT c = AcapGetContext(Device);
    NTSTATUS status = STATUS_SUCCESS;
    PCM_RESOURCE_DESCRIPTOR desc;
    ULONG i;
    ULONG count;
    ULONG magic;
    ULONG width;
    ULONG height;
    ULONG frame_bytes;
    WDF_DMA_ENABLER_CONFIG dmaConfig;
    WDF_COMMON_BUFFER_CONFIG cbConfig;
    LARGE_INTEGER la;

    UNREFERENCED_PARAMETER(ResourcesRaw);

    count = WdfCmResourceListGetCount(ResourcesTranslated);
    for (i = 0; i < count; i++) {
        desc = WdfCmResourceListGetDescriptor(ResourcesTranslated, i);
        if (desc && desc->Type == CmResourceTypeMemory && c->Bar == NULL) {
            c->BarPhys = desc->u.Memory.Start;
            c->BarLength = desc->u.Memory.Length;
            status = WdfDeviceMapIoSpace(Device, c->BarPhys, c->BarLength,
                                         MmNonCached, &c->Bar);
            if (!NT_SUCCESS(status))
                return status;
        }
    }

    if (c->Bar == NULL)
        return STATUS_DEVICE_CONFIGURATION_ERROR;

    magic = AcapReadReg(c, ACAP_REG_MAGIC);
    if (magic != ACAP_MAGIC)
        return STATUS_DEVICE_CONFIGURATION_ERROR;

    width = AcapReadReg(c, ACAP_REG_WIDTH);
    height = AcapReadReg(c, ACAP_REG_HEIGHT);
    frame_bytes = AcapReadReg(c, ACAP_REG_FRAME_BYTES);
    if (!width || !height || frame_bytes < ACAP_FRAME_HDR_SIZE ||
        frame_bytes > (64u << 20))
        return STATUS_DEVICE_CONFIGURATION_ERROR;

    c->FrameBytes = frame_bytes;
    c->BufStride = (frame_bytes + 0xFFF) & ~(SIZE_T)0xFFF;
    c->Nbuf = ACAP_NBUF;

    WDF_DMA_ENABLER_CONFIG_INIT(&dmaConfig, WdfDmaProfileScatterGather64,
                                c->BufStride);
    status = WdfDmaEnablerCreate(Device, &dmaConfig, WDF_NO_OBJECT_ATTRIBUTES,
                                 &c->DmaEnabler);
    if (!NT_SUCCESS(status)) {
        WDF_DMA_ENABLER_CONFIG_INIT(&dmaConfig, WdfDmaProfileScatterGather32,
                                    c->BufStride);
        status = WdfDmaEnablerCreate(Device, &dmaConfig,
                                     WDF_NO_OBJECT_ATTRIBUTES, &c->DmaEnabler);
        if (!NT_SUCCESS(status))
            return status;
    }

    WDF_COMMON_BUFFER_CONFIG_INIT(&cbConfig, 0x1000);
    for (i = 0; i < (ULONG)c->Nbuf; i++) {
        status = WdfCommonBufferCreateWithConfig(
            c->DmaEnabler, c->BufStride, &cbConfig,
            WDF_NO_OBJECT_ATTRIBUTES, &c->CommonBuffer[i]);
        if (!NT_SUCCESS(status))
            return status;

        c->BufVa[i] = WdfCommonBufferGetAlignedVirtualAddress(c->CommonBuffer[i]);
        c->BufLa[i] = WdfCommonBufferGetAlignedLogicalAddress(c->CommonBuffer[i]);
        if (!c->BufVa[i])
            return STATUS_INSUFFICIENT_RESOURCES;
    }

    AcapWriteReg(c, ACAP_REG_BUFFER_COUNT, (ULONG)c->Nbuf);
    for (i = 0; i < (ULONG)c->Nbuf; i++) {
        la.QuadPart = c->BufLa[i].QuadPart;
        AcapWriteReg(c, ACAP_REG_BUF_BASE + i * ACAP_REG_BUF_STRIDE + 0,
                     la.LowPart);
        AcapWriteReg(c, ACAP_REG_BUF_BASE + i * ACAP_REG_BUF_STRIDE + 4,
                     la.HighPart);
        AcapWriteReg(c, ACAP_REG_BUF_BASE + i * ACAP_REG_BUF_STRIDE + 12, 1);
    }

    AcapWriteReg(c, ACAP_REG_IRQ_STATUS, 0x7);
    AcapWriteReg(c, ACAP_REG_IRQ_ENABLE, 0);
    AcapWriteReg(c, ACAP_REG_CONTROL, 0);

    c->Started = FALSE;
    c->QueueStopped = FALSE;
    return STATUS_SUCCESS;
}

static NTSTATUS AcapEvtReleaseHardware(WDFDEVICE Device,
                                       WDFCMRESLIST ResourcesTranslated)
{
    PACAP_DEVICE_CONTEXT c = AcapGetContext(Device);

    UNREFERENCED_PARAMETER(ResourcesTranslated);

    AcapStop(c);

    if (c->Bar != NULL) {
        WdfDeviceUnmapIoSpace(Device, c->Bar, c->BarLength);
        c->Bar = NULL;
    }
    return STATUS_SUCCESS;
}

static NTSTATUS AcapEvtDeviceAdd(WDFDRIVER Driver, PWDFDEVICE_INIT DeviceInit)
{
    PACAP_DEVICE_CONTEXT c;
    WDFDEVICE device;
    WDF_OBJECT_ATTRIBUTES attributes;
    WDF_PNPPOWER_EVENT_CALLBACKS pnp;
    WDF_IO_QUEUE_CONFIG queueConfig;
    WDF_INTERRUPT_CONFIG interruptConfig;
    WDF_WORKITEM_CONFIG workConfig;
    NTSTATUS status;

    UNREFERENCED_PARAMETER(Driver);

    WdfDeviceInitSetIoType(DeviceInit, WdfDeviceIoBuffered);
    WdfDeviceInitSetExclusive(DeviceInit, TRUE);
    WdfDeviceInitAssignSDDLString(DeviceInit,
        L"D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;WD)");

    WDF_PNPPOWER_EVENT_CALLBACKS_INIT(&pnp);
    pnp.EvtDevicePrepareHardware = AcapEvtPrepareHardware;
    pnp.EvtDeviceReleaseHardware = AcapEvtReleaseHardware;
    WdfDeviceInitSetPnpPowerEventCallbacks(DeviceInit, &pnp);

    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attributes, ACAP_DEVICE_CONTEXT);
    status = WdfDeviceCreate(&DeviceInit, &attributes, &device);
    if (!NT_SUCCESS(status))
        return status;

    c = AcapGetContext(device);
    c->Device = device;

    {
        WDF_OBJECT_ATTRIBUTES objAttrs;
        WDF_OBJECT_ATTRIBUTES_INIT(&objAttrs);
        objAttrs.ParentObject = device;
        status = WdfSpinLockCreate(&objAttrs, &c->Lock);
        if (!NT_SUCCESS(status))
            return status;
    }

    WDF_IO_QUEUE_CONFIG_INIT(&queueConfig, WdfIoQueueDispatchManual);
    status = WdfIoQueueCreate(device, &queueConfig, WDF_NO_OBJECT_ATTRIBUTES,
                              &c->PendingQueue);
    if (!NT_SUCCESS(status))
        return status;

    WDF_IO_QUEUE_CONFIG_INIT_DEFAULT_QUEUE(&queueConfig,
                                           WdfIoQueueDispatchParallel);
    queueConfig.EvtIoRead = AcapEvtIoRead;
    queueConfig.EvtIoDeviceControl = AcapEvtIoDeviceControl;
    status = WdfIoQueueCreate(device, &queueConfig, WDF_NO_OBJECT_ATTRIBUTES,
                              WDF_NO_HANDLE);
    if (!NT_SUCCESS(status))
        return status;

    WDF_WORKITEM_CONFIG_INIT(&workConfig, AcapEvtWorkItem);
    workConfig.AutomaticSerialization = FALSE;
    {
        WDF_OBJECT_ATTRIBUTES objAttrs;
        WDF_OBJECT_ATTRIBUTES_INIT(&objAttrs);
        objAttrs.ParentObject = device;
        status = WdfWorkItemCreate(&workConfig, &objAttrs, &c->WorkItem);
        if (!NT_SUCCESS(status))
            return status;
    }

    WDF_INTERRUPT_CONFIG_INIT(&interruptConfig, AcapEvtInterruptIsr,
                              AcapEvtInterruptDpc);
    status = WdfInterruptCreate(device, &interruptConfig,
                                WDF_NO_OBJECT_ATTRIBUTES, &c->Interrupt);
    if (!NT_SUCCESS(status))
        return status;

    status = WdfDeviceCreateSymbolicLink(device, L"\\DosDevices\\ACAP0");
    if (!NT_SUCCESS(status))
        return status;

    return STATUS_SUCCESS;
}

NTSTATUS DriverEntry(PDRIVER_OBJECT DriverObject, PUNICODE_STRING RegistryPath)
{
    WDF_DRIVER_CONFIG config;
    WDFDRIVER driver;

    WDF_DRIVER_CONFIG_INIT(&config, AcapEvtDeviceAdd);
    return WdfDriverCreate(DriverObject, RegistryPath, WDF_NO_OBJECT_ATTRIBUTES,
                           &config, &driver);
}
