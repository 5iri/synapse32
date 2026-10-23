"""Small CRC16 XMODEM-1K sender for BusyBox rx; transport is supplied by caller."""
import binascii
import time

STX, EOT, ACK, NAK, CAN, CRC_REQUEST, PAD = 2, 4, 6, 21, 24, 67, 26


class TransferError(RuntimeError):
    pass


class Sender:
    def __init__(self, write, control, timeout=0.4, retries=5):
        if not 0 < timeout < 1:
            raise ValueError("data ACK timeout must be below BusyBox rx's one-second idle timeout")
        self.write, self.control = write, control
        self.timeout, self.retries = timeout, retries
        self.retransmissions = 0

    def send(self, data, progress=None):
        # rx removes trailing ^Z padding. A sentinel preserves genuine ^Z bytes
        # at EOF; the caller removes it by checking/truncating the exact size.
        stream = data + b'\0'
        initial = self.control(20.0)
        if initial != CRC_REQUEST:
            raise TransferError(f'receiver did not request CRC16 (received {initial!r})')
        started = time.monotonic()
        for index, offset in enumerate(range(0, len(stream), 1024)):
            payload = stream[offset:offset + 1024].ljust(1024, bytes([PAD]))
            number = (index + 1) & 255
            packet = bytes([STX, number, 255 - number]) + payload
            packet += binascii.crc_hqx(payload, 0).to_bytes(2, 'big')
            for attempt in range(self.retries + 1):
                self.write(packet)
                # BusyBox rx discards its pending block after one second idle;
                # retry before that boundary if an ACK disappears.
                reply = self.control(self.timeout)
                if reply == ACK:
                    break
                if reply == CAN:
                    raise TransferError('receiver canceled the transfer')
                if attempt == self.retries:
                    raise TransferError(f'block {index + 1} exceeded retry limit (reply {reply!r})')
                self.retransmissions += 1
            if progress:
                progress(min(offset + 1024, len(data)), len(data), self.retransmissions)
        self.write(bytes([EOT]))
        # rx exits immediately after EOT. Never resend EOT blindly into the shell
        # if this ACK is lost; fail safely and let the caller verify recovery.
        if self.control(self.timeout) != ACK:
            raise TransferError('missing EOT acknowledgement')
        return {'bytes': len(data), 'blocks': (len(stream) + 1023) // 1024,
                'retransmissions': self.retransmissions,
                'elapsed_seconds': time.monotonic() - started}
