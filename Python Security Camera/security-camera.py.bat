#@SETLOCAL ENABLEDELAYEDEXPANSION & start /B pythonw -x "%~f0" %* & EXIT /B !ERRORLEVEL!

import socket, tempfile

config = {
  "directories": {},
  "pre-init-urls": [],
  "post-init-urls": []
}
config["directories"]["temp"] = tempfile.gettempdir() + "/python_security_camera"
config["directories"]["temp_pictures"] = config["directories"]["temp"] + "/pictures"
config["directories"]["temp_log_file"] = config["directories"]["temp"] + "/app.log"
config["directories"]["saved_pictures"] = "Security Camera Pictures"
config["image_source"] = "http://192.168.1.100/snapshot.cgi?user=myusername&pwd=passhere"

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.connect(("192.168.1.211", 80))
computer_private_ip = sock.getsockname()[0]
sock.close()

config["pre-init-urls"].append("http://192.168.1.100/set_ftp.cgi?cam_user=myusername&cam_pwd=passhere&svr=" + computer_private_ip + "&port=8456&user=myusername&pwd=passhere&dir=a&mode=0")
#config["post-init-urls"].append("http://192.168.1.211/test_ftp.cgi?user=a&pwd=a12345")


import os

class System:

  @staticmethod
  def exists(path):
    return os.path.exists(path)

  @staticmethod
  def makedirs(path):
    logging.info("Directory created: " + path)
    os.makedirs(path)

  @staticmethod
  def remove(path):
    logging.info("File removed: " + path)
    os.remove(path)

  @staticmethod
  def rename(before, after):
    logging.info("File renamed: " + before + " --> " + after)
    os.rename(before, after)


import pyftpdlib as ftp, pyftpdlib.authorizers, pyftpdlib.handlers, pyftpdlib.servers, threading

class FTPCameraService(threading.Thread):

  class CameraFTPHandler(ftp.handlers.FTPHandler):
    def on_connect(self):
      self.server.connection_created = True

  def __init__(self, directory):
    super().__init__()
    self.authorizer = ftp.authorizers.DummyAuthorizer()

    self.handler = FTPCameraService.CameraFTPHandler
    self.handler.authorizer = self.authorizer

    self.server = ftp.servers.FTPServer(("0.0.0.0", 8456), self.handler)
    self.server.connection_created = False
    self.should_close = False
    self.timeout = 0.5

  def has_new_activity(self):
    if self.server.connection_created:
      self.server.connection_created = False
      return True
    return False

  def close(self):
    self.should_close = True
    self.join()

  def run(self):
    while not self.should_close:
      self.server.serve_forever(timeout=self.timeout, blocking=False)
    self.server.close_all()


from datetime import datetime, timedelta
import logging, mimetypes, os, requests, threading, time

class ImageDownloadScheduler(threading.Thread):
  ACTION_CAPTURE_TO_TEMP = 1
  ACTION_CAPTURE_TO_DIRECTORY = 2
  ACTION_CAPTURE_TO_DIRECTORY_START = 3

  def __init__(self):
    super().__init__()
    self.running = False
    self.error = None
    self.action = ImageDownloadScheduler.ACTION_CAPTURE_TO_TEMP

    self.temp_directory = ""
    self.directory = ""
    self.delay = 1.0
    self.input_address = ""

  def set_directory(self, directory):
    self.directory = directory
    if not System.exists(directory):
      System.makedirs(directory)

  def start_capture(self, directory):
    self.directory = directory
    self.action = ImageDownloadScheduler.ACTION_CAPTURE_TO_DIRECTORY_START

  def stop_capture(self):
    self.action = ImageDownloadScheduler.ACTION_CAPTURE_TO_TEMP

  def stop(self):
    self.running = False
    self.join()
    self.error = None

  def run(self):
    self.running = True
    self.next_capture_time = 0

    # Clear Temporary Directory
    self.clear_old_temp_images(0)

    while self.running:
      time.sleep(0.05)
      if time.time() > self.next_capture_time:
        try:

          if self.action == ImageDownloadScheduler.ACTION_CAPTURE_TO_TEMP:
            print("ACTION_CAPTURE_TO_TEMP")
            self.capture_image(self.temp_directory)
            self.clear_old_temp_images(30)

          elif self.action == ImageDownloadScheduler.ACTION_CAPTURE_TO_DIRECTORY_START:
            print("ACTION_CAPTURE_TO_DIRECTORY_START")
            directory = self.directory
            ImageDownloadScheduler.move_all_files_in_directory(self.temp_directory, directory)
            self.capture_image(directory)
            self.action = ImageDownloadScheduler.ACTION_CAPTURE_TO_DIRECTORY

          elif self.action == ImageDownloadScheduler.ACTION_CAPTURE_TO_DIRECTORY:
            print("ACTION_CAPTURE_TO_DIRECTORY")
            self.capture_image(self.directory)

          self.next_capture_time = time.time() + self.delay
        except Exception as ex:
          self.error = ex
          self.next_capture_time = time.time() + (self.delay * 4)

  @staticmethod
  def move_all_files_in_directory(old_directory, new_directory):
    if System.exists(old_directory):
      for file in os.listdir(old_directory):
        full_path = os.path.join(old_directory, file)
        if os.path.isfile(full_path):
          System.rename(full_path, os.path.join(new_directory, file))

  def clear_old_temp_images(self, age):
    temp = self.temp_directory
    if System.exists(temp):
      for file in os.listdir(temp):
        full_path = os.path.join(temp, file)
        if os.path.isfile(full_path):
          basename = os.path.splitext(file)
          created_datetime = datetime.strptime(basename[0], "%Y-%m-%d %H-%M-%S %f")
          # if the file is too old
          if age == 0 or (datetime.now() - created_datetime) > timedelta(seconds = age):
            System.remove(full_path)

  def capture_image(self, directory):
    image = requests.get(self.input_address)

    content_type = image.headers.get("content-type")
    extension = mimetypes.guess_extension(content_type)
    if extension is None:
      extension = ""
    elif extension == ".jpe" or extension == ".jpeg":
      extension = ".jpg"

    time = datetime.now().strftime("%Y-%m-%d %H-%M-%S %f")
    output_file = directory + "/" + time + extension

    logging.info("Created image: " + output_file)
    with open(output_file, "wb") as file:
      for chunk in image.iter_content(1024):
        file.write(chunk)


import time

class MotionDetectionService(object):
  def __init__(self, on_motion_start, on_motion_continue, on_motion_end, timeout = 60):
    self.timeout = timeout
    self.on_motion_start    = on_motion_start
    self.on_motion_continue = on_motion_continue
    self.on_motion_end      = on_motion_end
    self.stopping_time = None

  def wake(self):
    if self.stopping_time is None:
      self.on_motion_start()
    else:
      self.on_motion_continue()
    self.stopping_time = time.time() + self.timeout

  def check(self):
    if self.stopping_time is not None and time.time() > self.stopping_time:
      self.on_motion_end()
      self.stopping_time = None


from datetime import datetime, timedelta
import logging, os, random, requests, time, tkinter as tk, tkinter.font, tkinter.scrolledtext

class MonitorApplication(tk.Tk):

  @staticmethod
  def bring_to_front(window):
    window.lift()
    window.attributes("-topmost", True)
    window.attributes("-topmost", False)

  @staticmethod
  def shakescreen(window, seconds, shake_radius=5):
    def set_position(x, y):
      window.update_idletasks()
      width = window.winfo_width()
      height = window.winfo_height()
      window.geometry("{}x{}+{}+{}".format(width, height, x, y))
      window.update()
    def update():
      delta_x = random.randint(-shake_radius, shake_radius)
      delta_y = random.randint(-shake_radius, shake_radius)

      set_position(delta_x + update.original_x, delta_y + update.original_y)

      if time.time() > update.end_time:
        return
      window.after(10, update)
    update.original_x = window.winfo_x()
    update.original_y = window.winfo_y()
    update.end_time = time.time() + seconds
    update()

  def __init__(self):
    super().__init__()
    self.temp_picture_directory = config["directories"]["temp_pictures"]
    self.saved_directory = config["directories"]["saved_pictures"]

    self.title("Security Camera")
    self.create_widgets()

    self.filename_date_format = "%Y-%m-%d %H-%M-%S %f"

    self.motion_detection = MotionDetectionService(self.on_motion_start, self.on_motion_continue, self.on_motion_end, 30)

    self.ftp_service = FTPCameraService("ftp")
    self.ftp_service.start()
    logging.info("Started FTP service")

    self.download_scheduler = ImageDownloadScheduler()
    self.download_scheduler.delay = 0.5
    self.download_scheduler.input_address = config["image_source"]
    self.download_scheduler.temp_directory = self.temp_picture_directory
    self.download_scheduler.start()

    self.check()

  def after_init(self):
    for address in config["pre-init-urls"]:
      logging.info("Submitted request to " + address)
      response = requests.get(address)
      logging.info("Request: " + str(response.status_code))

  def on_motion_start(self):
    logging.info("Motion started")
    current_time = datetime.now()
    self.update_status(current_time.strftime("%B %d, %Y at %I:%M %p and %S seconds") + ": Motion detected")

    # Let's bug the user
    self.deiconify()
    MonitorApplication.shakescreen(self, 0.8, 10)
    MonitorApplication.bring_to_front(self)

    directory = self.saved_directory + "/" + current_time.strftime(self.filename_date_format)
    if not System.exists(directory):
      System.makedirs(directory)

    self.download_scheduler.start_capture(directory)

  def on_motion_continue(self):
    logging.info("Motion continued")

  def on_motion_end(self):
    logging.info("Motion ended")
    current_time = datetime.now()
    self.update_status(current_time.strftime("%B %d, %Y at %I:%M %p and %S seconds") + ": Motion stopped")
    self.download_scheduler.stop_capture()

  def check(self):
    if not self.download_scheduler.error is None:
      logging.error("Download scheduler error: " + str(self.download_scheduler.error))
      current_time = datetime.now()
      self.update_status(current_time.strftime("%B %d, %Y at %I:%M %p and %S seconds") + ": Download error!")
      self.download_scheduler.error = None

    if self.ftp_service.has_new_activity():
      self.motion_detection.wake()

    self.motion_detection.check()

    self.after(10, self.check)

  def update_status(self, status):
    self.status_label["text"] = status
    self.status_log.configure(state="normal")
    self.status_log.insert("1.0", status + "\r\n")
    self.status_log.configure(state="disabled")

  def on_test(self):
    self.motion_detection.wake()

  def create_widgets(self):
    header_font = tk.font.nametofont("TkDefaultFont").copy()
    header_font.configure(size=24)

    top_padding = 10
    content_frame = tk.Frame(self)
    content_frame.pack(pady=(top_padding, 0), expand=1, fill=tk.BOTH)

    menubar = tk.Menu(content_frame)
    self.config(menu=menubar)

    menubar.add_command(label="Test Drill", command=self.on_test)

    self.title_label = tk.Label(content_frame, font=header_font)
    self.title_label["text"] = "Security Camera"
    self.title_label.pack()

    self.status_label = tk.Label(content_frame)
    self.status_label.pack()


    self.status_log = tk.scrolledtext.ScrolledText(content_frame)
    self.status_log.pack(side=tk.LEFT, expand=1, fill=tk.BOTH)
    # read-only
    self.status_log.configure(state="disabled")
    self.status_log.bind("<1>", lambda event: self.status_log.focus_set())


    self.update()
    min_width  = self.winfo_width() // 2
    min_height = self.title_label.winfo_height() + top_padding + 100
    self.minsize(min_width, min_height)

    width = min_width * 1.2
    height = min_height * 1.2
    self.geometry(str(int(width)) + "x" + str(int(height)))

  def on_close(self):
    logging.info("Closing application")

    self.ftp_service.close()
    logging.info("Successfully stopped FTP service")

    self.download_scheduler.stop_capture()
    self.download_scheduler.stop()
    logging.info("Successfully stopped the download scheduler")


directory = config["directories"]["temp_pictures"]
if not System.exists(directory):
  System.makedirs(directory)

directory = config["directories"]["saved_pictures"]
if not System.exists(directory):
  System.makedirs(directory)

logging.basicConfig(filename=config["directories"]["temp_log_file"], level=logging.INFO, format="%(asctime)s %(levelname)s %(lineno)d %(name)s: %(message)s")

app = MonitorApplication()
try:
  app.after_init()
  app.mainloop()
except Exception as ex:
  logging.exception("Uncaught exception!")

  import webbrowser
  webbrowser.open(config["directories"]["temp_log_file"])
finally:
  app.on_close()
