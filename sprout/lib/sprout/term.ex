defmodule Sprout.Term do
  @moduledoc """
  Low-level primitives for manipulating the terminal emulator.
  """
  use See

  ~C"""
  #include <stdbool.h>
  #include <termios.h>
  #include <sys/ioctl.h>

  static struct termios orig;

  bool enable_raw() {
      if (tcgetattr(0, &orig) != 0) return false;

      struct termios raw = orig;

      raw.c_iflag &= ~(unsigned int)(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
      raw.c_oflag &= ~(unsigned int)(OPOST);
      raw.c_cflag |= (unsigned int)(CS8);
      raw.c_lflag &= ~(unsigned int)(ECHO | ICANON | IEXTEN | ISIG);
      raw.c_cc[VMIN] = 0;
      raw.c_cc[VTIME] = 0;

      return tcsetattr(0, TCSAFLUSH, &raw) == 0;
  }

  bool disable_raw() {
      return tcsetattr(0, TCSAFLUSH, &orig) == 0;
  }

  int winsize_rows() {
      struct winsize ws;
      if (ioctl(0, TIOCGWINSZ, &ws) != 0) return 0;
      return ws.ws_row;
  }

  int winsize_cols() {
      struct winsize ws;
      if (ioctl(0, TIOCGWINSZ, &ws) != 0) return 0;
      return ws.ws_col;
  }
  """
end