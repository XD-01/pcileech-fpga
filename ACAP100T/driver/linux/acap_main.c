/*
 * ACAP-100T PCIe video capture driver (Linux)
 *
 * The device is a 4 kB BAR0 register file plus a ring of frame buffers in
 * host memory.  The FPGA writes complete YUYV frames into the buffers with
 * posted PCIe memory-write TLPs and raises a single MSI at frame completion.
 *
 * /dev/acap0 is a small capture API:
 *   - ioctl(GET_INFO)         dimensions / frame size / buffer count
 *   - mmap()                  map all frame buffers (zero copy)
 *   - ioctl(START/STOP)       start / stop the DMA engine
 *   - ioctl(WAIT_FRAME)       dequeue a completed buffer
 *   - ioctl(RELEASE_FRAME)    acknowledge and recycle the buffer
 *   - read()                  copy the next complete buffer (header + payload)
 *
 * The module is auto-loaded by the PCI modalias table after installation.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/pci.h>
#include <linux/miscdevice.h>
#include <linux/fs.h>
#include <linux/uaccess.h>
#include <linux/dma-mapping.h>
#include <linux/interrupt.h>
#include <linux/wait.h>
#include <linux/poll.h>
#include <linux/slab.h>
#include <linux/io.h>
#include <linux/mm.h>
#include <linux/atomic.h>
#include <linux/byteorder/generic.h>
#include <linux/version.h>

#include "acap_uapi.h"
#include "acap_ioctl.h"

#define ACAP_DRV_NAME   "acap"
#define ACAP_DRV_VERSION "1.0.0"

struct acap_dev {
    struct pci_dev      *pdev;
    void __iomem        *bar;
    struct miscdevice    misc;
    int                  irq;

    spinlock_t           lock;
    wait_queue_head_t    wq;
    atomic_t             in_use;

    void                *buf_cpu;
    dma_addr_t           buf_dma;
    size_t               frame_bytes;
    size_t               buf_stride;
    size_t               total_size;
    int                  nbuf;

    bool                 started;
    u32                  done_shadow;
    u8                   queue[ACAP_MAX_BUFFERS];
    unsigned int         q_head;
    unsigned int         q_tail;
    unsigned int         q_count;
};

static int nbuf_param = 4;
module_param_named(buffers, nbuf_param, int, 0444);
MODULE_PARM_DESC(buffers, "number of frame buffers (1..8, default 4)");

static inline u32 acap_rd(struct acap_dev *d, u32 off)
{
    return readl(d->bar + off);
}

static inline void acap_wr(struct acap_dev *d, u32 off, u32 val)
{
    writel(val, d->bar + off);
}

static inline bool acap_queue_empty(struct acap_dev *d)
{
    unsigned long flags;
    bool empty;

    spin_lock_irqsave(&d->lock, flags);
    empty = (d->q_count == 0);
    spin_unlock_irqrestore(&d->lock, flags);
    return empty;
}

static void acap_flush_queue(struct acap_dev *d)
{
    unsigned long flags;

    spin_lock_irqsave(&d->lock, flags);
    d->q_head = 0;
    d->q_tail = 0;
    d->q_count = 0;
    d->done_shadow = 0;
    spin_unlock_irqrestore(&d->lock, flags);
}

static irqreturn_t acap_isr(int irq, void *arg)
{
    struct acap_dev *d = arg;
    u32 status;
    u32 done;
    u32 fresh;
    int i;

    status = acap_rd(d, ACAP_REG_IRQ_STATUS);
    if (!status)
        return IRQ_NONE;

    acap_wr(d, ACAP_REG_IRQ_STATUS, status);

    done = acap_rd(d, ACAP_REG_BUF_DONE);

    spin_lock(&d->lock);
    fresh = done & ~d->done_shadow;
    for (i = 0; i < ACAP_MAX_BUFFERS; i++) {
        if (fresh & (1u << i)) {
            d->done_shadow |= (1u << i);
            if (d->q_count < ACAP_MAX_BUFFERS) {
                d->queue[d->q_tail] = (u8)i;
                d->q_tail = (d->q_tail + 1) % ACAP_MAX_BUFFERS;
                d->q_count++;
            }
        }
    }
    spin_unlock(&d->lock);

    wake_up_interruptible(&d->wq);
    return IRQ_HANDLED;
}

/* Returns 0 and an index, or a negative errno. */
static int acap_dequeue(struct acap_dev *d, u8 *index)
{
    unsigned long flags;
    int ret;

    ret = wait_event_interruptible_timeout(
        d->wq,
        (!d->started) || !acap_queue_empty(d),
        msecs_to_jiffies(2000));

    if (ret == 0)
        return -ETIMEDOUT;
    if (ret < 0)
        return ret;
    if (!d->started)
        return -EIO;

    spin_lock_irqsave(&d->lock, flags);
    if (d->q_count == 0) {
        spin_unlock_irqrestore(&d->lock, flags);
        return -EAGAIN;
    }
    *index = d->queue[d->q_head];
    d->q_head = (d->q_head + 1) % ACAP_MAX_BUFFERS;
    d->q_count--;
    spin_unlock_irqrestore(&d->lock, flags);
    return 0;
}

/* Clear the device done bit first, then the software shadow bit. */
static void acap_release(struct acap_dev *d, u8 index)
{
    unsigned long flags;

    if (index >= ACAP_MAX_BUFFERS)
        return;

    acap_wr(d, ACAP_REG_BUF_ACK, 1u << index);

    spin_lock_irqsave(&d->lock, flags);
    d->done_shadow &= ~(1u << index);
    spin_unlock_irqrestore(&d->lock, flags);
}

static int acap_fill_info(struct acap_dev *d, struct acap_info *info)
{
    memset(info, 0, sizeof(*info));
    info->magic = acap_rd(d, ACAP_REG_MAGIC);
    info->version = acap_rd(d, ACAP_REG_VERSION);
    info->width = acap_rd(d, ACAP_REG_WIDTH);
    info->height = acap_rd(d, ACAP_REG_HEIGHT);
    info->stride = acap_rd(d, ACAP_REG_STRIDE);
    info->format = acap_rd(d, ACAP_REG_FORMAT);
    info->frame_bytes = d->frame_bytes;
    info->buffer_stride = d->buf_stride;
    info->buffer_count = d->nbuf;
    info->caps = acap_rd(d, ACAP_REG_CAPS);
    info->pixel_clock_hz = acap_rd(d, ACAP_REG_PIXEL_CLK_HZ);
    return 0;
}

static int acap_start(struct acap_dev *d)
{
    acap_flush_queue(d);
    acap_wr(d, ACAP_REG_IRQ_STATUS, 0x7);
    acap_wr(d, ACAP_REG_IRQ_ENABLE, ACAP_IRQ_FRAME_DONE | ACAP_IRQ_FRAME_STALL);
    acap_wr(d, ACAP_REG_CONTROL, ACAP_CTRL_ENABLE);
    d->started = true;
    return 0;
}

static void acap_stop(struct acap_dev *d)
{
    d->started = false;
    acap_wr(d, ACAP_REG_CONTROL, 0);
    acap_wr(d, ACAP_REG_IRQ_ENABLE, 0);
    wake_up_interruptible_all(&d->wq);
}

static ssize_t acap_read(struct file *file, char __user *ubuf,
                         size_t count, loff_t *ppos)
{
    struct acap_dev *d = file->private_data;
    u8 index;
    int ret;

    if (count < d->frame_bytes)
        return -EINVAL;

    ret = acap_dequeue(d, &index);
    if (ret)
        return ret;

    dma_rmb();
    if (copy_to_user(ubuf, (char *)d->buf_cpu + (size_t)index * d->buf_stride,
                     d->frame_bytes)) {
        acap_release(d, index);
        return -EFAULT;
    }

    acap_release(d, index);
    return d->frame_bytes;
}

static int acap_open(struct inode *inode, struct file *file)
{
    struct acap_dev *d = container_of(file->private_data,
                                      struct acap_dev, misc);

    if (atomic_cmpxchg(&d->in_use, 0, 1) != 0)
        return -EBUSY;

    file->private_data = d;
    return 0;
}

static int acap_release_file(struct inode *inode, struct file *file)
{
    struct acap_dev *d = file->private_data;

    acap_stop(d);
    atomic_set(&d->in_use, 0);
    return 0;
}

static __poll_t acap_poll(struct file *file, poll_table *wait)
{
    struct acap_dev *d = file->private_data;
    __poll_t mask = 0;

    poll_wait(file, &d->wq, wait);
    if (!acap_queue_empty(d))
        mask |= EPOLLIN | EPOLLRDNORM;
    if (!d->started)
        mask |= EPOLLERR;
    return mask;
}

static int acap_mmap(struct file *file, struct vm_area_struct *vma)
{
    struct acap_dev *d = file->private_data;
    unsigned long size = vma->vm_end - vma->vm_start;

    if (vma->vm_pgoff != 0 || size > d->total_size)
        return -EINVAL;

    vma->vm_flags |= VM_DONTEXPAND | VM_DONTDUMP;
    return dma_mmap_coherent(&d->pdev->dev, vma, d->buf_cpu,
                             d->buf_dma, size);
}

static long acap_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
    struct acap_dev *d = file->private_data;
    struct acap_info info;
    struct acap_frame frame;
    u32 index;

    switch (cmd) {
    case ACAP_IOC_GET_INFO:
        acap_fill_info(d, &info);
        if (copy_to_user((void __user *)arg, &info, sizeof(info)))
            return -EFAULT;
        return 0;

    case ACAP_IOC_START:
        return acap_start(d);

    case ACAP_IOC_STOP:
        acap_stop(d);
        return 0;

    case ACAP_IOC_WAIT_FRAME: {
        struct acap_frame_hdr *h;
        u8 idx;
        int ret = acap_dequeue(d, &idx);

        if (ret)
            return ret;

        dma_rmb();
        h = (struct acap_frame_hdr *)((char *)d->buf_cpu +
                                      (size_t)idx * d->buf_stride);
        memset(&frame, 0, sizeof(frame));
        frame.buffer_index = idx;
        frame.bytes = d->frame_bytes;
        if (le32_to_cpu(h->magic0) == ACAP_HDR_MAGIC0 &&
            le32_to_cpu(h->magic1) == ACAP_HDR_MAGIC1) {
            frame.seq = le32_to_cpu(h->seq);
            frame.timestamp_ns =
                ((u64)le32_to_cpu(h->ts_hi) << 32) |
                (u64)le32_to_cpu(h->ts_lo);
        }
        if (copy_to_user((void __user *)arg, &frame, sizeof(frame))) {
            acap_release(d, idx);
            return -EFAULT;
        }
        return 0;
    }

    case ACAP_IOC_RELEASE_FRAME:
        if (copy_from_user(&index, (void __user *)arg, sizeof(index)))
            return -EFAULT;
        acap_release(d, (u8)index);
        return 0;

    default:
        return -ENOTTY;
    }
}

static const struct file_operations acap_fops = {
    .owner          = THIS_MODULE,
    .open           = acap_open,
    .release        = acap_release_file,
    .read           = acap_read,
    .poll           = acap_poll,
    .mmap           = acap_mmap,
    .unlocked_ioctl = acap_ioctl,
};

static int acap_setup_buffers(struct acap_dev *d)
{
    u64 addr;
    int i;

    acap_wr(d, ACAP_REG_BUFFER_COUNT, d->nbuf);

    for (i = 0; i < d->nbuf; i++) {
        addr = (u64)d->buf_dma + (u64)i * d->buf_stride;
        acap_wr(d, ACAP_REG_BUF_BASE + i * ACAP_REG_BUF_STRIDE + 0,
                lower_32_bits(addr));
        acap_wr(d, ACAP_REG_BUF_BASE + i * ACAP_REG_BUF_STRIDE + 4,
                upper_32_bits(addr));
        /* bit 0 = valid, also clears the done bit for this buffer */
        acap_wr(d, ACAP_REG_BUF_BASE + i * ACAP_REG_BUF_STRIDE + 12, 1);
    }
    return 0;
}

static int acap_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
    struct acap_dev *d;
    u32 magic, version, width, height, frame_bytes;
    int ret;

    d = devm_kzalloc(&pdev->dev, sizeof(*d), GFP_KERNEL);
    if (!d)
        return -ENOMEM;

    d->pdev = pdev;
    spin_lock_init(&d->lock);
    init_waitqueue_head(&d->wq);
    atomic_set(&d->in_use, 0);

    ret = pci_enable_device(pdev);
    if (ret)
        return ret;

    pci_set_master(pdev);

    ret = pci_request_regions(pdev, ACAP_DRV_NAME);
    if (ret)
        goto err_disable;

    d->bar = pci_iomap(pdev, 0, 0);
    if (!d->bar) {
        ret = -ENOMEM;
        goto err_regions;
    }

    magic = acap_rd(d, ACAP_REG_MAGIC);
    version = acap_rd(d, ACAP_REG_VERSION);
    if (magic != ACAP_MAGIC) {
        dev_err(&pdev->dev, "bad MAGIC 0x%08x\n", magic);
        ret = -ENODEV;
        goto err_unmap;
    }

    width = acap_rd(d, ACAP_REG_WIDTH);
    height = acap_rd(d, ACAP_REG_HEIGHT);
    frame_bytes = acap_rd(d, ACAP_REG_FRAME_BYTES);
    if (!width || !height || frame_bytes < ACAP_FRAME_HDR_SIZE ||
        frame_bytes > (64u << 20)) {
        dev_err(&pdev->dev, "invalid geometry %ux%u frame_bytes=%u\n",
                width, height, frame_bytes);
        ret = -ENODEV;
        goto err_unmap;
    }

    d->frame_bytes = frame_bytes;
    d->buf_stride = PAGE_ALIGN(d->frame_bytes);
    d->nbuf = clamp(nbuf_param, 1, ACAP_MAX_BUFFERS);
    d->total_size = d->buf_stride * d->nbuf;

    ret = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(64));
    if (ret)
        ret = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(32));
    if (ret) {
        dev_err(&pdev->dev, "no usable DMA mask\n");
        goto err_unmap;
    }

    d->buf_cpu = dma_alloc_coherent(&pdev->dev, d->total_size,
                                    &d->buf_dma, GFP_KERNEL);
    if (!d->buf_cpu) {
        ret = -ENOMEM;
        goto err_unmap;
    }
    if (((unsigned long)d->buf_cpu & ~PAGE_MASK) ||
        ((u64)d->buf_dma & (PAGE_SIZE - 1))) {
        dev_err(&pdev->dev, "DMA buffer is not page aligned\n");
        ret = -ENOMEM;
        goto err_free_buf;
    }

    ret = pci_alloc_irq_vectors(pdev, 1, 1, PCI_IRQ_MSI);
    if (ret < 0) {
        dev_err(&pdev->dev, "MSI allocation failed: %d\n", ret);
        goto err_free_buf;
    }
    d->irq = pci_irq_vector(pdev, 0);

    ret = request_irq(d->irq, acap_isr, 0, ACAP_DRV_NAME, d);
    if (ret) {
        dev_err(&pdev->dev, "request_irq failed: %d\n", ret);
        goto err_vectors;
    }

    acap_setup_buffers(d);
    acap_wr(d, ACAP_REG_IRQ_STATUS, 0x7);
    acap_wr(d, ACAP_REG_IRQ_ENABLE, 0);
    acap_wr(d, ACAP_REG_CONTROL, 0);

    d->misc.minor = MISC_DYNAMIC_MINOR;
    d->misc.name = "acap0";
    d->misc.fops = &acap_fops;
    d->misc.parent = &pdev->dev;
    ret = misc_register(&d->misc);
    if (ret) {
        dev_err(&pdev->dev, "misc_register failed: %d\n", ret);
        goto err_irq;
    }

    pci_set_drvdata(pdev, d);

    dev_info(&pdev->dev,
             "ACAP-100T %ux%u YUYV, %u frame buffers, %zu bytes each, MSI %d\n",
             width, height, d->nbuf, d->frame_bytes, d->irq);
    return 0;

err_irq:
    free_irq(d->irq, d);
err_vectors:
    pci_free_irq_vectors(pdev);
err_free_buf:
    dma_free_coherent(&pdev->dev, d->total_size, d->buf_cpu, d->buf_dma);
err_unmap:
    pci_iounmap(pdev, d->bar);
err_regions:
    pci_release_regions(pdev);
err_disable:
    pci_disable_device(pdev);
    return ret;
}

static void acap_remove(struct pci_dev *pdev)
{
    struct acap_dev *d = pci_get_drvdata(pdev);

    if (!d)
        return;

    acap_stop(d);
    misc_deregister(&d->misc);
    free_irq(d->irq, d);
    pci_free_irq_vectors(pdev);
    dma_free_coherent(&pdev->dev, d->total_size, d->buf_cpu, d->buf_dma);
    pci_iounmap(pdev, d->bar);
    pci_release_regions(pdev);
    pci_disable_device(pdev);
}

static const struct pci_device_id acap_pci_ids[] = {
    { PCI_DEVICE(0x1AB2, 0x1001) },
    { 0, }
};
MODULE_DEVICE_TABLE(pci, acap_pci_ids);

static struct pci_driver acap_pci_driver = {
    .name     = ACAP_DRV_NAME,
    .id_table = acap_pci_ids,
    .probe    = acap_probe,
    .remove   = acap_remove,
};

module_pci_driver(acap_pci_driver);

MODULE_AUTHOR("ACAP-100T");
MODULE_DESCRIPTION("ACAP-100T PCIe video capture driver");
MODULE_VERSION(ACAP_DRV_VERSION);
MODULE_LICENSE("GPL");
