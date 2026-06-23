import sys
import termios
import tty

def get_char():
    fd = sys.stdin.fileno()
    old_settings = termios.tcgetattr(fd)
    try:
        tty.setraw(sys.stdin.fileno())
        ch = sys.stdin.read(1)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)
    return ch

def main():
    log_file = sys.argv[1] if len(sys.argv) > 1 else "key_log.txt"
    with open(log_file, "w", encoding="utf-8") as f:
        f.write("[LOG] Started key logger\n")
        f.flush()
        
        while True:
            ch = get_char()
            if not ch:
                break
            # Log char hex and display
            repr_str = ch.encode('utf-8').hex()
            if ch == '\x1b':
                f.write("KEY: ESCAPE\n")
            elif ch == '\n' or ch == '\r':
                f.write("KEY: ENTER\n")
            else:
                f.write(f"CHAR: {ch} (hex: {repr_str})\n")
            f.flush()

if __name__ == "__main__":
    main()
