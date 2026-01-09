#import <substrate.h>
#import <ellekit/ellekit.hpp>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <GLKit/GLKit.h>
#include <vector>
#include <string>
#include <cmath>
#include <dlfcn.h>

#define M_PI 3.14159265358979323846f
#define MAX_PLAYERS 16

namespace Config {
    bool esp = true, aimbot = true, norecoil = true, chams = true, radar = true, thirdperson = false;
    float aim_fov = 90.0f, aim_smooth = 8.0f, speed_mult = 1.5f;
} using namespace Config;

// Structs
struct Vec3 { float x, y, z; Vec3 operator-(const Vec3& o) { return {x - o.x, y - o.y, z - o.z}; } };
struct Mat4 { float m[16]; };

// Globals (1.52.7 from 1.52.4 dump + pattern)
uintptr_t il2cpp_base = 0, gameplay_module = 0, view_matrix = 0;
uintptr_t recoil_rva = 0x1A2B3C4; // Update from dump
uintptr_t ac_check_rva = 0x3ABCDEF; // Update

// Pattern scan
uintptr_t scan_pattern(uintptr_t start, size_t size, const char* pat, const char* mask) {
    const char* p = pat;
    for (uintptr_t addr = start; addr < start + size; ++addr) {
        bool found = true;
        for (int i = 0; i < strlen(mask); ++i) {
            if (mask[i] != '?' && memcmp((void*)(addr + i), &p[i * 3], 1)) { found = false; break; }
        }
        if (found) return addr;
    }
    return 0;
}

void init_offsets() {
    il2cpp_base = (uintptr_t)dlopen("libil2cpp.so", RTLD_NOW);
    if (!il2cpp_base) return;

    // GameplayModule string sig
    gameplay_module = scan_pattern(il2cpp_base, 0x4000000, "GameplayModule", "xxxxxxxxxxxxxx");

    // ViewMatrix identity pattern (stable 1.52.x)
    view_matrix = scan_pattern(il2cpp_base, 0x4000000, "\x7F\x00\x00\x00\x00\x00\x00\x00", "xxxxxxxx");

    // Recoil/AC from dump (update post-dump)
}

// Player getters (offsets stable +0x20 GameSystem, +0xC0 CharMan, +0x10 Local)
void* get_gameplay_module() { return *(void**)(gameplay_module + 0x20); }
void* get_local_player() {
    void* gs = *(void**)((uintptr_t)get_gameplay_module() + 0xC0);
    return *(void**)((uintptr_t)gs + 0x10);
}
std::vector<void*> get_enemies() {
    std::vector<void*> enemies;
    void* local = get_local_player();
    if (!local) return enemies;
    void* manager = *(void**)((uintptr_t)local + 0x10); // CharManager approx
    for (int i = 0; i < MAX_PLAYERS; ++i) {
        void* player = *(void**)((uintptr_t)manager + i * 0x8);
        if (player && player != local) {
            float health = *(float*)((uintptr_t)player + 0x2F8);
            if (health > 1.0f && health <= 100.0f) enemies.push_back(player);
        }
    }
    return enemies;
}

// W2S
bool world_to_screen(Vec3 pos, Vec3& screen, int screen_w = 1170, int screen_h = 2532) {
    if (!view_matrix) return false;
    Mat4 matrix = *(Mat4*)view_matrix;
    float x = matrix.m[0] * pos.x + matrix.m[4] * pos.y + matrix.m[8] * pos.z + matrix.m[12];
    float y = matrix.m[1] * pos.x + matrix.m[5] * pos.y + matrix.m[9] * pos.z + matrix.m[13];
    float w = matrix.m[3] * pos.x + matrix.m[7] * pos.y + matrix.m[11] * pos.z + matrix.m[15];
    if (w < 0.01f) return false;
    float inv_w = 1.0f / w;
    screen.x = screen_w / 2.0f + (x * inv_w) * screen_w / 2.0f;
    screen.y = screen_h / 2.0f - (y * inv_w) * screen_h / 2.0f;
    return true;
}

// Calc aim angles
Vec3 calc_aim(Vec3 from, Vec3 to) {
    Vec3 delta = to - from;
    float dist = sqrtf(delta.x * delta.x + delta.y * delta.y);
    return {asinf(delta.z / dist) * 57.2958f, atan2f(delta.y, delta.x) * 57.2958f, 0};
}

// NoRecoil Hook
EK::Interceptor recoil_interceptor;
void recoil_hk(EK::APIs::Registers& regs) {
    if (norecoil) {
        *(float*)(regs.sp + 0x50) = 0.0f; // pitch
        *(float*)(regs.sp + 0x54) = 0.0f; // yaw
    }
}

// ESP/Chams/Radar GL Hook
EK::Interceptor gl_draw_interceptor;
void gl_esp_hk(EK::APIs::Registers& regs) {
    glDisable(GL_DEPTH_TEST);
    if (chams) {
        glColor4f(1.0f, 0.0f, 0.0f, 0.8f); // Red chams
    }

    if (esp || radar) {
        auto enemies = get_enemies();
        Vec3 local_pos = *(Vec3*)((uintptr_t)get_local_player() + 0x1A0);
        for (auto enemy : enemies) {
            Vec3 pos = *(Vec3*)((uintptr_t)enemy + 0x1A0);
            Vec3 head = pos; head.z += 1.8f; // Head approx
            Vec3 foot_screen, head_screen;
            if (world_to_screen(pos, foot_screen) && world_to_screen(head, head_screen)) {
                float box_height = foot_screen.y - head_screen.y;
                float box_width = box_height * 0.5f;
                // ESP Box
                if (esp) {
                    glLineWidth(3.0f);
                    glColor4f(1.0f, 0.0f, 0.0f, 1.0f);
                    glBegin(GL_LINE_LOOP);
                    glVertex2f(foot_screen.x - box_width, foot_screen.y);
                    glVertex2f(foot_screen.x + box_width, foot_screen.y);
                    glVertex2f(foot_screen.x + box_width, head_screen.y);
                    glVertex2f(foot_screen.x - box_width, head_screen.y);
                    glEnd();
                    // Health Bar
                    float health = *(float*)((uintptr_t)enemy + 0x2F8);
                    glColor4f(0.0f, 1.0f, 0.0f, 1.0f);
                    glBegin(GL_QUADS);
                    glVertex2f(foot_screen.x - box_width - 6, head_screen.y);
                    glVertex2f(foot_screen.x - box_width - 6 + (health / 100.0f * 12), head_screen.y);
                    glVertex2f(foot_screen.x - box_width - 6 + (health / 100.0f * 12), foot_screen.y);
                    glVertex2f(foot_screen.x - box_width - 6, foot_screen.y);
                    glEnd();
                }
                // Radar Dot (top-left mini)
                if (radar) {
                    float dx = (pos.x - local_pos.x) / 50.0f;
                    float dy = (pos.y - local_pos.y) / 50.0f;
                    glColor4f(1.0f, 1.0f, 0.0f, 1.0f);
                    glBegin(GL_POINTS);
                    glVertex2f(50 + dx, 50 + dy);
                    glEnd();
                }
            }
        }
    }
    glEnable(GL_DEPTH_TEST);
}

// Aimbot Hook (view angles)
EK::Interceptor aim_interceptor;
void aimbot_hk(EK::APIs::Registers& regs) {
    if (!aimbot) return;
    void* local = get_local_player();
    if (!local) return;
    Vec3 local_pos = *(Vec3*)((uintptr_t)local + 0x1A0);
    Vec3 best_target = {0};
    float best_dist = aim_fov;
    auto enemies = get_enemies();
    for (auto enemy : enemies) {
        Vec3 head_pos = *(Vec3*)((uintptr_t)enemy + 0x1A0 + 0x30); // Head bone
        float dist_2d = hypotf(head_pos.x - local_pos.x, head_pos.y - local_pos.y);
        if (dist_2d < best_dist) {
            best_dist = dist_2d;
            best_target = head_pos;
        }
    }
    if (best_dist < aim_fov) {
        Vec3 angles = calc_aim(local_pos, best_target);
        float* pitch = (float*)(regs.x0 + 0x10); // Adjust per dump
        float* yaw = (float*)(regs.x0 + 0x14);
        float factor = 1.0f / aim_smooth;
        *pitch = (*pitch * (1.0f - factor)) + (angles.x * factor) + ((rand() % 10 - 5) * 0.1f); // Jitter
        *yaw = (*yaw * (1.0f - factor)) + (angles.y * factor) + ((rand() % 10 - 5) * 0.1f);
    }
}

// AC Bypass
EK::Interceptor ac_interceptor;
void ac_bypass_hk(EK::APIs::Registers&) { /* NOP */ }

// Menu (simple vol toggle + overlay, full ImGui via lib later)
%hook UIDevice
- (void)setVolume:(float)volume {
    %orig;
    if (volume > 0.8f) esp = !esp; // Vol up toggle ESP
    if (volume < 0.2f) aimbot = !aimbot; // Vol down toggle aim
}
%end

%ctor {
    init_offsets();
    // Hooks (RVA from dump - update below)
    recoil_interceptor.hook((void*)(il2cpp_base + recoil_rva), recoil_hk);
    gl_draw_interceptor.hook_symbol("glDrawArrays", gl_esp_hk);
    aim_interceptor.hook((void*)(il2cpp_base + 0x2ABCDEF), aimbot_hk); // View update RVA
    ac_interceptor.hook((void*)(il2cpp_base + ac_check_rva), ac_bypass_hk);
}
