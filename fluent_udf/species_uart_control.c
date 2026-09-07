#include <udf.h>
#include <para.h>
#include <fcntl.h>
#include <termios.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>
#include <math.h>

#define UART_BAUD B115200
#define TIMEOUT_S 0
#define TIMEOUT_US 50000  /* 50 ms UART reply timeout */

#define OUTLET_ZONE_ID 7   /* pressure-outlet-7 */
#define SENSOR_MAX 0.2     /* sensor saturates at Y_he = 0.2 */

/* Paths default to the original project layout but can be overridden with
   STHIL_ROOT so the same binary works in checkpoint copies. */
#define ROOT_DEFAULT "/home/nulltype/Projects/ST-HIL"
#define FRAME_JOURNAL_DEFAULT ROOT_DEFAULT "/fluent_udf/auto_frame.jou"
#define FRAME_DIR_DEFAULT     ROOT_DEFAULT "/fluent_udf/frames"

/* Default adaptive-frame thresholds.  Override with STHIL_Y_THRESHOLD and
   STHIL_CMD_THRESHOLD environment variables (read once at first call). */
#define Y_THRESHOLD_DEFAULT   0.0005
#define CMD_THRESHOLD_DEFAULT 2

/* Default minimum frame interval if the user does not set
   STHIL_MIN_FRAME_EVERY.  A value of 1 means save every time step;
   this guarantees the animation is never empty when the flow settles. */
#define DEFAULT_MIN_FRAME_EVERY 1

/* FPGA diagnostic frame: host sends 0xBB, FPGA replies with 16 bytes
   [sensor, filtered, setpoint, duty, Kp, Ki, slew, max_duty, filter,
    deadband, watchdog, button, 0, 0, 0, 0].
   The real FPGA firmware (species_fsm.v) replies to 0xBB with 16 bytes;
   the BL702 echo channel does not.  We therefore probe with 0xAA 0x00 and
   then verify that a subsequent 0xBB yields exactly 16 bytes. */
#define DIAG_FRAME_LEN 16
#define DIAG_SYNC_BYTE 0xBB
#define SENSOR_SYNC_BYTE 0xAA

static int fd = -1;              /* UART file descriptor */
static int current_cmd = 0xFF;   /* last FPGA command: 0-255 duty (0 = stop) */
static int last_sync_iter = -1;  /* guard: only sync once per iteration */
static int consecutive_failures = 0;
static int force_software = 0;   /* set by STHIL_FORCE_SOFTWARE env var */
static int cmd_threshold_report = CMD_THRESHOLD_DEFAULT; /* for log throttling */


static int  frame_index    = 0;
static int  frames_saved   = 0;

/* Adaptive frame-save state */
static real last_saved_y   = -1.0;
static int  last_saved_cmd = -1;

/* ------------------------------------------------------------------------- */
/* Software PI controller fallback (mirrors species_fsm.v exactly)           */
/* ------------------------------------------------------------------------- */

typedef struct
{
    int setpoint;
    int kp;
    int ki;
    int slew;
    int max_duty;
    int filter;
    int deadband;

    int sensor_filtered;
    int duty_prev;
    int integrator;
} software_controller_t;

/* Defaults tuned for a visible demo plume when no FPGA is connected.
   The FPGA has its own power-up values in species_fsm.v; these defaults
   only affect the software fallback path.  They can be overridden with
   environment variables. */
static software_controller_t sw_ctrl = {
    100,  /* setpoint */
    8,    /* kp */
    0,    /* ki */
    32,   /* slew */
    255,  /* max_duty */
    128,  /* filter */
    2,    /* deadband */
    0, 0, 0
};

static void load_sw_ctrl_defaults(void)
{
    const char *env;
    env = getenv("STHIL_SETPOINT");   if (env && env[0]) sw_ctrl.setpoint   = atoi(env);
    env = getenv("STHIL_KP");         if (env && env[0]) sw_ctrl.kp         = atoi(env);
    env = getenv("STHIL_KI");         if (env && env[0]) sw_ctrl.ki         = atoi(env);
    env = getenv("STHIL_SLEW");       if (env && env[0]) sw_ctrl.slew       = atoi(env);
    env = getenv("STHIL_MAX_DUTY");   if (env && env[0]) sw_ctrl.max_duty   = atoi(env);
    env = getenv("STHIL_FILTER");     if (env && env[0]) sw_ctrl.filter     = atoi(env);
    env = getenv("STHIL_DEADBAND");   if (env && env[0]) sw_ctrl.deadband   = atoi(env);
}

static int software_controller_step(software_controller_t *c, int sensor_byte)
{
    c->sensor_filtered = (sensor_byte * c->filter + c->sensor_filtered * (255 - c->filter)) >> 8;

    int error_raw = c->setpoint - c->sensor_filtered;
    int error;
    if (error_raw > c->deadband)
        error = error_raw - c->deadband;
    else if (error_raw < -c->deadband)
        error = error_raw + c->deadband;
    else
        error = 0;

    int p_term = error * c->kp;
    int pi_sum = p_term + c->integrator;
    int pi_out = pi_sum;
    if (pi_out > 255) pi_out = 255;
    if (pi_out < 0)   pi_out = 0;

    int next_duty;
    if (pi_out > c->duty_prev + c->slew)
        next_duty = c->duty_prev + c->slew;
    else if (pi_out < c->duty_prev - c->slew)
        next_duty = c->duty_prev - c->slew;
    else
        next_duty = pi_out;

    if (next_duty > c->max_duty)
        next_duty = c->max_duty;

    int new_integrator = c->integrator + error * c->ki;
    if (new_integrator > 8191)  new_integrator = 8191;
    if (new_integrator < -8192) new_integrator = -8192;
    c->integrator = new_integrator;

    c->duty_prev = next_duty;
    return next_duty;
}

/* ------------------------------------------------------------------------- */
/* Low-level UART helpers                                                    */
/* ------------------------------------------------------------------------- */

static int try_open_port(const char *device)
{
    int tmp_fd = open(device, O_RDWR | O_NOCTTY | O_NDELAY);
    if (tmp_fd < 0) return -1;

    /* Keep the descriptor non-blocking so read()/select() cannot hang us. */
    int flags = fcntl(tmp_fd, F_GETFL, 0);
    fcntl(tmp_fd, F_SETFL, flags | O_NDELAY);

    struct termios tty;
    memset(&tty, 0, sizeof(tty));
    if (tcgetattr(tmp_fd, &tty) < 0)
    {
        close(tmp_fd);
        return -1;
    }

    cfsetispeed(&tty, UART_BAUD);
    cfsetospeed(&tty, UART_BAUD);

    tty.c_cflag = CS8 | CLOCAL | CREAD;
    tty.c_iflag = 0;
    tty.c_oflag = 0;
    tty.c_lflag = 0;

    tty.c_cc[VMIN]  = 0;
    tty.c_cc[VTIME] = 0;  /* purely non-blocking reads */

    if (tcsetattr(tmp_fd, TCSANOW, &tty) < 0)
    {
        close(tmp_fd);
        return -1;
    }

    tcflush(tmp_fd, TCIOFLUSH);
    return tmp_fd;
}

/* Drain any stale bytes from the receive buffer before a fresh exchange. */
static void uart_drain(int tmp_fd)
{
    unsigned char drain[64];
    int loops = 0;
    while (loops < 10)
    {
        fd_set rfds;
        struct timeval tv;
        FD_ZERO(&rfds);
        FD_SET(tmp_fd, &rfds);
        tv.tv_sec  = 0;
        tv.tv_usec = 10000;  /* 10 ms per drain attempt */

        if (select(tmp_fd + 1, &rfds, NULL, NULL, &tv) <= 0)
            break;

        if (read(tmp_fd, drain, sizeof(drain)) <= 0)
            break;

        loops++;
    }
}

/* Probe a port by first sending a normal control frame (0xAA 0x00) and
   then requesting the diagnostic dump (0xBB).  The real FPGA firmware
   replies to 0xAA with one duty byte and to 0xBB with exactly 16 bytes.
   The BL702 echo channel may echo the 0xAA frame but will not produce a
   16-byte 0xBB reply, so this reliably identifies the correct port. */
static int probe_port(int tmp_fd)
{
    unsigned char ping[2] = {SENSOR_SYNC_BYTE, 0x00};
    unsigned char reply[DIAG_FRAME_LEN];
    int got = 0;

    tcflush(tmp_fd, TCIOFLUSH);

    /* First ping: any single-byte reply is acceptable here. */
    if (write(tmp_fd, ping, 2) != 2)
        return 0;

    fd_set rfds;
    struct timeval tv;
    FD_ZERO(&rfds);
    FD_SET(tmp_fd, &rfds);
    tv.tv_sec  = 0;
    tv.tv_usec = 200000;  /* 200 ms */
    if (select(tmp_fd + 1, &rfds, NULL, NULL, &tv) <= 0)
        return 0;
    unsigned char dummy;
    if (read(tmp_fd, &dummy, 1) != 1)
        return 0;

    /* Now ask for the diagnostic dump.  Only the real FPGA answers 16 bytes. */
    unsigned char req = DIAG_SYNC_BYTE;
    if (write(tmp_fd, &req, 1) != 1)
        return 0;

    /* Wait up to 300 ms for the full diagnostic frame. */
    double elapsed_ms = 0.0;
    while (elapsed_ms < 300.0 && got < DIAG_FRAME_LEN)
    {
        FD_ZERO(&rfds);
        FD_SET(tmp_fd, &rfds);
        tv.tv_sec  = 0;
        tv.tv_usec = 20000;  /* 20 ms slices */

        if (select(tmp_fd + 1, &rfds, NULL, NULL, &tv) > 0)
        {
            ssize_t n = read(tmp_fd, reply + got, DIAG_FRAME_LEN - got);
            if (n > 0)
                got += (int)n;
        }
        elapsed_ms += 20.0;
    }

    return (got == DIAG_FRAME_LEN);
}

static int uart_open(void)
{
    if (fd >= 0) return 0;

    /* Tang Nano 20K debugger exposes two interfaces:
       if00 -> BL702 secondary channel (may echo old firmware)
       if01 -> FPGA UART (the one we want)
       Prefer the by-id symlink, then /dev/ttyUSB1, then scan. */
    const char *preferred[] = {
        "/dev/serial/by-id/usb-SIPEED_USB_Debugger_2025030317-if01-port0",
        "/dev/ttyUSB1",
        NULL
    };

    for (int k = 0; preferred[k] != NULL; k++)
    {
        int tmp_fd = try_open_port(preferred[k]);
        if (tmp_fd < 0)
            continue;
        if (probe_port(tmp_fd))
        {
            fd = tmp_fd;
            Message0("species_uart_control: opened %s\n", preferred[k]);
            return 0;
        }
        close(tmp_fd);
    }

    char path[64];
    const char *patterns[] = {"/dev/ttyUSB%d", "/dev/ttyACM%d"};
    int max_idx[] = {9, 3};

    for (int p = 0; p < 2; p++)
    {
        for (int i = 0; i <= max_idx[p]; i++)
        {
            snprintf(path, sizeof(path), patterns[p], i);

            int tmp_fd = try_open_port(path);
            if (tmp_fd < 0)
                continue;

            if (probe_port(tmp_fd))
            {
                fd = tmp_fd;
                Message0("species_uart_control: opened %s\n", path);
                return 0;
            }

            close(tmp_fd);
        }
    }

    static int fail_msg_logged = 0;
    if (!fail_msg_logged)
    {
        fail_msg_logged = 1;
        Message0("species_uart_control: failed to find FPGA on any UART port; using software fallback\n");
    }
    fd = -1;
    return -1;
}

/* Send 0xAA + sensor byte, read 1-byte duty command from FPGA.
   Uses a short select() timeout and a non-blocking read so the Fluent
   solver never stalls waiting for the FPGA. */
static int uart_sync_and_read(unsigned char sensor_byte, unsigned char *cmd)
{
    if (fd < 0) return -1;

    /* Discard anything left over from a previous exchange or echo. */
    uart_drain(fd);

    unsigned char frame[2] = {SENSOR_SYNC_BYTE, sensor_byte};
    ssize_t nw = write(fd, frame, 2);
    if (nw != 2) return -1;

    fd_set rfds;
    struct timeval tv;
    FD_ZERO(&rfds);
    FD_SET(fd, &rfds);
    tv.tv_sec  = TIMEOUT_S;
    tv.tv_usec = TIMEOUT_US;

    int rv = select(fd + 1, &rfds, NULL, NULL, &tv);
    if (rv <= 0) return -1;

    ssize_t n = read(fd, cmd, 1);
    return (n == 1) ? 0 : -1;
}

/* ------------------------------------------------------------------------- */
/* Sensor computation                                                        */
/* ------------------------------------------------------------------------- */

/* Compute area-averaged helium mass fraction at the outlet (zone 7).
   Runs on every process that owns part of the outlet face thread;
   the partial sums are reduced across compute nodes. */
static real compute_outlet_he_fraction(void)
{
    real sum_y_a = 0.0;
    real sum_a   = 0.0;

    Domain *domain = Get_Domain(1);
    if (domain != NULL)
    {
        Thread *t = Lookup_Thread(domain, OUTLET_ZONE_ID);
        if (t != NULL && BOUNDARY_FACE_THREAD_P(t))
        {
            face_t f;
            begin_f_loop(f, t)
            {
                real area[ND_ND];
                real a_mag;
                real y_he;
                F_AREA(area, f, t);
                a_mag = NV_MAG(area);
                y_he = F_YI(f, t, 0); /* species-0 = helium */
                sum_y_a += y_he * a_mag;
                sum_a   += a_mag;
            }
            end_f_loop(f, t)
        }
    }

#if RP_NODE
    sum_y_a = PRF_GRSUM1(sum_y_a);
    sum_a   = PRF_GRSUM1(sum_a);
#endif

    if (sum_a > 0.0)
        return sum_y_a / sum_a;
    return 0.0;
}

/* ------------------------------------------------------------------------- */
/* Feedback loop (runs once per iteration, on every compute node)            */
/* ------------------------------------------------------------------------- */

/* Update current_cmd from the FPGA.  This is called from DEFINE_ADJUST,
   which Fluent invokes once per iteration on all compute nodes, so the
   MPI reductions inside are symmetric and safe. */
static unsigned char sensor_byte_from_y(real y_outlet)
{
    if (y_outlet >= SENSOR_MAX)
        return 255;
    return (unsigned char)((y_outlet / SENSOR_MAX) * 255.0);
}

static void update_fpga_command(int iter)
{
    real y_outlet = compute_outlet_he_fraction();

    int cmd_local = 0;  /* only node-0 drives the UART; others contribute 0 */
    int is_controller = 1;
#if RP_NODE
    is_controller = I_AM_NODE_ZERO_P;
#endif

    if (is_controller)
    {
        unsigned char sensor_byte = sensor_byte_from_y(y_outlet);

        if (iter == 1)
        {
            const char *env = getenv("STHIL_FORCE_SOFTWARE");
            force_software = (env != NULL && (env[0] == '1' || env[0] == 'y' || env[0] == 'Y'));
            if (force_software)
                Message0("species_uart_control: software fallback forced by STHIL_FORCE_SOFTWARE\n");
        }

        if (force_software)
        {
            cmd_local = software_controller_step(&sw_ctrl, sensor_byte);
        }
        else
        {
            /* Retry UART open only every 10 iterations when previously failed,
               so an unplugged FPGA does not spam the console every step. */
            static int last_open_attempt_iter = -999;
            if (fd < 0 && (iter - last_open_attempt_iter) >= 10)
            {
                last_open_attempt_iter = iter;
                uart_open();
            }

            if (fd >= 0)
            {
                unsigned char cmd = 0x00;
                if (uart_sync_and_read(sensor_byte, &cmd) == 0)
                {
                    cmd_local = (int)cmd;
                    consecutive_failures = 0;
                    static int last_reported_cmd = -1;
                    if (abs(cmd - last_reported_cmd) > cmd_threshold_report || iter <= 1)
                    {
                        last_reported_cmd = cmd;
                        Message0("species_uart_control: duty=0x%02X (%.3f)  outlet Y_he=%.4f  iter=%d\n",
                                 cmd, cmd / 255.0, y_outlet, iter);
                    }
                }
                else
                {
                    consecutive_failures++;
                    static int timeout_logged = 0;
                    if (!timeout_logged)
                    {
                        timeout_logged = 1;
                        Message0("species_uart_control: UART timeout/no reply; switching to software fallback\n");
                    }
                    if (consecutive_failures >= 3)
                    {
                        Message0("species_uart_control: %d consecutive failures, closing UART to re-sync\n",
                                 consecutive_failures);
                        close(fd);
                        fd = -1;
                        consecutive_failures = 0;
                    }
                    /* Use software controller while UART is unavailable. */
                    cmd_local = software_controller_step(&sw_ctrl, sensor_byte);
                }
            }
            else
            {
                cmd_local = software_controller_step(&sw_ctrl, sensor_byte);
            }
        }

        static int last_reported_cmd = -1;
        if (abs(cmd_local - last_reported_cmd) > cmd_threshold_report || iter <= 1)
        {
            last_reported_cmd = cmd_local;
            Message0("species_uart_control: duty=0x%02X (%.3f)  outlet Y_he=%.4f  iter=%d  source=%s\n",
                     cmd_local, cmd_local / 255.0, y_outlet, iter,
                     force_software ? "software" : (fd >= 0 ? "fpga" : "fallback"));
        }
    }

#if RP_NODE
    /* Broadcast the command from node-0.  Only node-0 sets a non-zero value
       (0-255), so the global integer sum reproduces node-0's command. */
    current_cmd = PRF_GISUM1(cmd_local);
#else
    current_cmd = cmd_local;
#endif
}

/* ------------------------------------------------------------------------- */
/* Adaptive frame-save journal writer                                        */
/* ------------------------------------------------------------------------- */

/* Decide whether the current state differs enough from the last saved frame.
   If so, write a journal snippet that renders and saves the next frame.
   Only node-0 writes the file; all ranks compute the same decision because
   current_cmd and y_outlet are globally reduced. */
static void write_frame_journal(int iter)
{
    int is_controller = 1;
#if RP_NODE
    is_controller = I_AM_NODE_ZERO_P;
#endif

    static int save_all_frames = -1;
    static int min_frame_every = -1;
    static int steps_since_save = 0;
    static real y_threshold = -1.0;
    static int cmd_threshold = -1;
    if (save_all_frames < 0)
    {
        const char *env = getenv("STHIL_SAVE_ALL_FRAMES");
        save_all_frames = (env != NULL && (env[0] == '1' || env[0] == 'y' || env[0] == 'Y'));
        if (save_all_frames)
            Message0("species_uart_control: saving every frame (STHIL_SAVE_ALL_FRAMES)\n");

        const char *env_min = getenv("STHIL_MIN_FRAME_EVERY");
        if (env_min != NULL && env_min[0] != '\0')
            min_frame_every = atoi(env_min);
        if (min_frame_every < 0)
            min_frame_every = DEFAULT_MIN_FRAME_EVERY;

        const char *env_y = getenv("STHIL_Y_THRESHOLD");
        y_threshold = (env_y != NULL && env_y[0] != '\0') ? atof(env_y) : Y_THRESHOLD_DEFAULT;
        if (y_threshold < 0.0)
            y_threshold = Y_THRESHOLD_DEFAULT;

        const char *env_cmd = getenv("STHIL_CMD_THRESHOLD");
        cmd_threshold = (env_cmd != NULL && env_cmd[0] != '\0') ? atoi(env_cmd) : CMD_THRESHOLD_DEFAULT;
        if (cmd_threshold < 0)
            cmd_threshold = CMD_THRESHOLD_DEFAULT;
        cmd_threshold_report = cmd_threshold;

        Message0("species_uart_control: frame mode save_all=%d min_every=%d y_thr=%g cmd_thr=%d\n",
                 save_all_frames, min_frame_every, y_threshold, cmd_threshold);
    }

    Domain *domain = Get_Domain(1);
    if (domain == NULL) return;

    real y_outlet = compute_outlet_he_fraction();
    steps_since_save++;

    int save_needed = save_all_frames;
    if (!save_needed)
    {
        if (last_saved_y < 0.0)
        {
            save_needed = 1;
        }
        else if (fabs(y_outlet - last_saved_y) > y_threshold)
        {
            save_needed = 1;
        }
        else if (abs(current_cmd - last_saved_cmd) > cmd_threshold)
        {
            save_needed = 1;
        }
        else if (min_frame_every > 0 && steps_since_save >= min_frame_every)
        {
            save_needed = 1;
        }
    }

    Message0("species_uart_control: FRAME_DECISION iter=%d y=%.5f duty=%d steps=%d save=%d\n",
             iter, y_outlet, current_cmd, steps_since_save, save_needed);

    if (save_needed)
    {
        last_saved_y   = y_outlet;
        last_saved_cmd = current_cmd;
        frame_index++;
        frames_saved++;
        steps_since_save = 0;
    }

    if (is_controller)
    {
        const char *root = getenv("STHIL_ROOT");
        if (root == NULL || root[0] == '\0')
            root = ROOT_DEFAULT;

        char frame_journal[1024];
        char frame_dir[1024];
        snprintf(frame_journal, sizeof(frame_journal), "%s/fluent_udf/auto_frame.jou", root);
        snprintf(frame_dir, sizeof(frame_dir), "%s/fluent_udf/frames", root);

        FILE *fj = fopen(frame_journal, "w");
        if (fj != NULL)
        {
            /* Each sub-journal must set this itself; the parent setting does
               not always carry over when the sub-journal is read. */
            fprintf(fj, "/file/confirm-overwrite? no\n");
            /* Working recipe in Fluent 2026 R1 null-driver mode:
               enable non-object-based workflow, then use space-separated
               "driver png"; the slash form and use-window-resolution? are
               invalid in this version. */
            fprintf(fj, "/preferences/graphics/enable-non-object-based-workflow yes\n");
            fprintf(fj, "/display/set/picture/driver png\n");
            fprintf(fj, "/display/set/picture/x-resolution 1280\n");
            fprintf(fj, "/display/set/picture/y-resolution 720\n");

            if (save_needed)
            {
                /* The execute-at-end hook fires once per time step, so name
                   frames by time-step number rather than iteration number.
                   With 10 inner iterations per time step, step = iter/10.
                   The initial frame (saved by the journal before step 1) is
                   helium_adaptive_0000.png; UDF frames start at 0001. */
                int time_step = iter / 10;
                fprintf(fj, "; auto-frame time_step=%d iter=%d y=%.5f duty=%d\n",
                        time_step, iter, y_outlet, current_cmd);
                fprintf(fj, "/display/contour he 0 1\n");
                fprintf(fj, "/display/save-picture %s/helium_adaptive_%04d.png\n",
                        frame_dir, time_step);
            }
            else
            {
                fprintf(fj, "; no significant change at iter=%d y=%.5f duty=%d\n",
                        iter, y_outlet, current_cmd);
            }
            fclose(fj);
        }
    }
}

/* ------------------------------------------------------------------------- */
/* Fluent hooks                                                              */
/* ------------------------------------------------------------------------- */

/* Called once per iteration at the start of the iteration.  Safe place for
   the UART exchange because every compute node enters it symmetrically.
   In serial mode Fluent runs as host, so we must NOT return on RP_HOST
   blindly; only skip the parallel host process which has no mesh data. */
DEFINE_ADJUST(fpga_feedback_loop, domain)
{
#if RP_HOST && !RP_NODE
    /* This branch is taken by the serial solver AND the parallel host.
       The parallel host has no mesh data; detect it by a NULL domain/thread. */
    if (domain == NULL || Lookup_Thread(domain, OUTLET_ZONE_ID) == NULL)
        return;
#endif

    int iter = N_ITER;
    if (iter <= 0) return;              /* skip initialization */
    if (iter == last_sync_iter) return; /* already synced this iteration */

    last_sync_iter = iter;
    update_fpga_command(iter);
}

/* Apply the FPGA command to the helium inlet species mass fraction.
   The FPGA now replies with an 8-bit duty (0 = stop, 255 = full helium).
   This hook must stay cheap and non-blocking because it runs inside the
   solver coefficient assembly. */
DEFINE_PROFILE(species_mass_fraction, t, i)
{
    face_t f;
    real y_he = (current_cmd > 0) ? ((real)current_cmd / 255.0) : 0.0;

    /* Log once per iteration so we can verify the profile hook is active
       and the command is reaching the helium inlet. */
    static int last_profile_iter = -1;
    if (N_ITER != last_profile_iter)
    {
        last_profile_iter = N_ITER;
        Message0("species_uart_control: PROFILE iter=%d current_cmd=%d y_he=%.5f\n",
                 N_ITER, current_cmd, y_he);
    }

    begin_f_loop(f, t)
    {
        F_PROFILE(f, t, i) = y_he;
    }
    end_f_loop(f, t)
}

/* Write the adaptive frame journal at the end of each iteration.
   Skip iteration 0 (hybrid initialization) because the parent journal
   already saves the explicit initial frame as helium_adaptive_0000.png. */
DEFINE_EXECUTE_AT_END(write_adaptive_frame)
{
#if RP_HOST
    return;
#endif
    if (N_ITER > 0)
        write_frame_journal(N_ITER);
}

/* Ensure the frames directory exists once at initialization and load any
   software-fallback config overrides from the environment. */
DEFINE_INIT(make_frames_dir, domain)
{
    const char *root = getenv("STHIL_ROOT");
    if (root == NULL || root[0] == '\0')
        root = ROOT_DEFAULT;

    char frame_dir[1024];
    snprintf(frame_dir, sizeof(frame_dir), "mkdir -p %s/fluent_udf/frames", root);

    load_sw_ctrl_defaults();
    system(frame_dir);
}
