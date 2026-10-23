using System;
using System.Drawing;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Forms;
using System.Windows.Forms.Integration;
using System.Windows.Media;

namespace Vx.Operator {
    // No hardware access. Windows' installed media framework owns decoding.
    public sealed class MediaWindow : Form {
        readonly ElementHost host;
        readonly MediaElement video;
        readonly PictureBox image;
        bool opened;
        double lastPosition;
        DateTime lastProgress;
        DateTime started;
        public string Mode { get; private set; }
        public bool Success { get; private set; }
        public string Message { get; private set; }
        public bool CoverAllowed { get; private set; }
        protected override bool ShowWithoutActivation { get { return true; } }

        public MediaWindow(bool preview) {
            AutoScaleMode = AutoScaleMode.None;
            FormBorderStyle = preview ? FormBorderStyle.FixedToolWindow : FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            ShowInTaskbar = preview;
            TopMost = !preview;
            BackColor = System.Drawing.Color.Black;
            video = new MediaElement {
                LoadedBehavior = MediaState.Manual, UnloadedBehavior = MediaState.Manual,
                IsMuted = true, Volume = 0, Stretch = Stretch.Uniform
            };
            host = new ElementHost { Dock = DockStyle.Fill, Child = video, Visible = false };
            image = new PictureBox { Dock = DockStyle.Fill, BackColor = System.Drawing.Color.Black,
                SizeMode = PictureBoxSizeMode.Zoom, Visible = false };
            Controls.Add(host); Controls.Add(image);
            video.MediaOpened += delegate {
                if (Mode != "Video") return;
                opened = true;
                if (video.NaturalVideoWidth <= 0 || video.NaturalVideoHeight <= 0)
                    Fail("The selected file has no decodable video track.");
            };
            video.MediaFailed += delegate(object sender, ExceptionRoutedEventArgs args) {
                Fail("Windows media decoder failed: " + args.ErrorException.Message);
            };
            video.MediaEnded += delegate {
                if (Mode == "Video") { video.Position = TimeSpan.Zero; lastPosition = 0; video.Play(); }
            };
            Mode = "Input"; Message = "Waiting for engine command.";
        }

        protected override void Dispose(bool disposing) {
            try { if (disposing) Clear(); } finally { base.Dispose(disposing); }
        }
        void Clear() {
            video.Stop(); video.Close(); video.Source = null;
            host.Visible = false; image.Visible = false;
            if (image.Image != null) { var previous = image.Image; image.Image = null; previous.Dispose(); }
            opened = false; Success = false;
        }
        public void BindOutput(Rectangle bounds) { Bounds = bounds; CoverAllowed = true; }
        public void RevokeOutput() { CoverAllowed = false; Hide(); }
        public void Fail(string reason) {
            // Cover the selected input until the engine has acknowledged hardware blackout.
            // Hiding here would expose the Windows desktop while the device is still Normal.
            Success = false; Message = reason;
            try { Clear(); } catch { host.Visible = false; image.Visible = false; }
            if (CoverAllowed) { Show(); Invalidate(); Update(); } else Hide();
        }
        public void Output(string mode, string videoFile, string imageFile) {
            Clear(); Mode = mode; Message = "Opening " + mode + ".";
            if (mode == "Input" || mode == "Stop") {
                Hide(); Success = true; Message = "Output hidden."; return;
            }
            if (mode == "Black") {
                using (var original = System.Drawing.Image.FromFile(imageFile)) image.Image = new Bitmap(original);
                image.Visible = true; image.BringToFront(); Show(); image.Refresh(); Update();
                Success = true; Message = "Black image rendered."; return;
            }
            if (mode != "Video") throw new ArgumentException("Unknown media mode.");
            started = lastProgress = DateTime.UtcNow; lastPosition = 0;
            host.Visible = true; host.BringToFront(); Show();
            video.Source = new Uri(videoFile, UriKind.Absolute); video.Play();
        }
        public void PollPlayback() {
            if (Mode != "Video" || !Visible) return;
            double position = video.Position.TotalMilliseconds;
            if (opened && position > lastPosition + 1) {
                Success = true; Message = "Video playing (opened and playback clock advancing).";
                lastProgress = DateTime.UtcNow;
            }
            lastPosition = position;
            if ((!Success && (DateTime.UtcNow - started).TotalSeconds > 8) ||
                (Success && (DateTime.UtcNow - lastProgress).TotalSeconds > 8))
                Fail("Video did not start or playback stopped advancing within 8 seconds.");
        }
    }
}
