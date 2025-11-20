/*
 *   sonic-agent  Agent of Sonic Cloud Real Machine Platform.
 *   Copyright (C) 2022 SonicCloudOrg
 *
 *   This program is free software: you can redistribute it and/or modify
 *   it under the terms of the GNU Affero General Public License as published
 *   by the Free Software Foundation, either version 3 of the License, or
 *   (at your option) any later version.
 *
 *   This program is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *   GNU Affero General Public License for more details.
 *
 *   You should have received a copy of the GNU Affero General Public License
 *   along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */
package org.cloud.sonic.agent.tests.android;

import com.android.ddmlib.IDevice;
import org.cloud.sonic.agent.bridge.android.AndroidDeviceBridgeTool;
import org.cloud.sonic.agent.tests.handlers.AndroidStepHandler;
import org.cloud.sonic.agent.tools.file.UploadTools;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.File;
import java.util.Calendar;

/**
 * android 录像线程
 *
 * @author Eason(main) JayWenStar(until e1a877b7)
 * @date 2021/12/2 12:29 上午
 */
public class AndroidRecordThread extends Thread {

    private final Logger log = LoggerFactory.getLogger(AndroidRecordThread.class);

    /**
     * 占用符逻辑参考：{@link AndroidTestTaskBootThread#ANDROID_TEST_TASK_BOOT_PRE}
     */
    public final static String ANDROID_RECORD_TASK_PRE = "android-record-task-%s-%s-%s";

    private final AndroidTestTaskBootThread androidTestTaskBootThread;

    public AndroidRecordThread(AndroidTestTaskBootThread androidTestTaskBootThread) {
        this.androidTestTaskBootThread = androidTestTaskBootThread;

        this.setDaemon(true);
        this.setName(androidTestTaskBootThread.formatThreadName(ANDROID_RECORD_TASK_PRE));
    }

    public AndroidTestTaskBootThread getAndroidTestTaskBootThread() {
        return androidTestTaskBootThread;
    }

    @Override
    public void run() {
        AndroidStepHandler androidStepHandler = androidTestTaskBootThread.getAndroidStepHandler();
        AndroidRunStepThread runStepThread = androidTestTaskBootThread.getRunStepThread();
        String udId = androidTestTaskBootThread.getUdId();
        IDevice iDevice = null;
        String remoteVideoPath = null;

        try {
            iDevice = AndroidDeviceBridgeTool.getIDeviceByUdId(udId);
            final IDevice finalDevice = iDevice; // 用于 lambda 表达式
            
            // 等待 AndroidDriver 初始化
            while (runStepThread.isAlive() && androidStepHandler.getAndroidDriver() == null) {
                try {
                    Thread.sleep(500);
                } catch (InterruptedException e) {
                    log.error(e.getMessage());
                    return;
                }
            }
            
            if (androidStepHandler.getAndroidDriver() == null) {
                log.warn("AndroidDriver not initialized, skipping recording");
                return;
            }

            // 生成设备上的视频文件路径
            long timeMillis = Calendar.getInstance().getTimeInMillis();
            remoteVideoPath = "/sdcard/sonic_record_" + timeMillis + "_" + udId.substring(0, Math.min(4, udId.length())) + ".mp4";
            
            // 启动 ADB screenrecord 命令（最多录制 10 分钟，比特率 4Mbps）
            log.info("Starting ADB screenrecord: {}", remoteVideoPath);
            // 使用异步方式执行 screenrecord 命令（在后台运行）
            String recordCommand = String.format("screenrecord --time-limit 600 --bit-rate 4000000 %s", remoteVideoPath);
            
            // 在单独的线程中异步执行 screenrecord（这样不会阻塞）
            Thread recordThread = new Thread(() -> {
                try {
                    finalDevice.executeShellCommand(recordCommand, new com.android.ddmlib.IShellOutputReceiver() {
                        @Override
                        public void addOutput(byte[] data, int offset, int length) {
                            // screenrecord 通常不输出内容，除非有错误
                            String output = new String(data, offset, length);
                            if (output.trim().length() > 0) {
                                log.debug("Screenrecord output: {}", output);
                            }
                        }

                        @Override
                        public void flush() {
                        }

                        @Override
                        public boolean isCancelled() {
                            return false;
                        }
                    }, 0, java.util.concurrent.TimeUnit.MILLISECONDS);
                } catch (Exception e) {
                    log.error("Failed to execute screenrecord command: {}", e.getMessage());
                }
            });
            recordThread.setDaemon(true);
            recordThread.start();
            
            log.info("ADB screenrecord command started in background");
            
            // 等待一下确保命令启动
            Thread.sleep(2000);
            
            // 验证 screenrecord 进程是否在运行
            String pidCheck = AndroidDeviceBridgeTool.executeCommand(finalDevice, "ps | grep screenrecord | grep -v grep");
            if (pidCheck == null || pidCheck.trim().isEmpty()) {
                // 尝试另一种方式查找进程
                pidCheck = AndroidDeviceBridgeTool.executeCommand(finalDevice, "ps -A | grep screenrecord");
                if (pidCheck == null || pidCheck.trim().isEmpty()) {
                    log.warn("Screenrecord process not found immediately, but continuing (may need more time to start)");
                } else {
                    log.info("ADB screenrecord process found via ps -A");
                }
            } else {
                log.info("ADB screenrecord process found and running");
            }
            
            // 等待测试完成
            while (runStepThread.isAlive()) {
                try {
                    Thread.sleep(1000);
                } catch (InterruptedException e) {
                    log.error(e.getMessage());
                    break;
                }
            }
            
            // 停止录制：screenrecord 会在达到时间限制或收到 SIGINT 时自动停止
            log.info("Stopping ADB screenrecord...");
            try {
                // 查找 screenrecord 进程并终止（使用 ps 命令）
                String pidOutput = AndroidDeviceBridgeTool.executeCommand(finalDevice, "ps | grep screenrecord | grep -v grep");
                if (pidOutput == null || pidOutput.trim().isEmpty()) {
                    // 尝试另一种方式
                    pidOutput = AndroidDeviceBridgeTool.executeCommand(finalDevice, "ps -A | grep screenrecord");
                }
                
                if (pidOutput != null && !pidOutput.trim().isEmpty()) {
                    // 解析 PID（通常是第二列）
                    String[] lines = pidOutput.trim().split("\n");
                    for (String line : lines) {
                        if (line.contains("screenrecord")) {
                            String[] parts = line.trim().split("\\s+");
                            if (parts.length >= 2) {
                                String pid = parts[1]; // PID 通常在第二列
                                try {
                                    AndroidDeviceBridgeTool.executeCommand(finalDevice, "kill -2 " + pid);
                                    log.info("Sent SIGINT to screenrecord process: {}", pid);
                                } catch (Exception e) {
                                    log.warn("Failed to kill screenrecord process {}: {}", pid, e.getMessage());
                                }
                            }
                        }
                    }
                } else {
                    log.info("Screenrecord process not found, may have already stopped");
                }
                // 等待录制完成（等待文件写入）
                Thread.sleep(3000);
            } catch (Exception e) {
                log.warn("Failed to stop screenrecord gracefully: {}", e.getMessage());
            }
            
            // 等待文件写入完成
            Thread.sleep(1000);
            
            // 处理录像文件
            File recordDir = new File("test-output/record");
            if (!recordDir.exists()) {
                recordDir.mkdirs();
            }
            String fileName = timeMillis + "_" + udId.substring(0, Math.min(4, udId.length())) + ".mp4";
            File localVideoFile = new File(recordDir + File.separator + fileName);
            
            try {
                // 从设备拉取视频文件
                log.info("Pulling video file from device: {} -> {}", remoteVideoPath, localVideoFile.getAbsolutePath());
                
                // 确保目录存在
                localVideoFile.getParentFile().mkdirs();
                
                // 使用 ddmlib 的 pullFile 方法
                finalDevice.pullFile(remoteVideoPath, localVideoFile.getAbsolutePath());
                
                // 等待文件传输完成
                int waitCount = 0;
                while (!localVideoFile.exists() && waitCount < 10) {
                    Thread.sleep(500);
                    waitCount++;
                }
                
                // 检查文件是否存在且大小大于 0
                if (!localVideoFile.exists()) {
                    log.warn("Video file not found after pull: {}", localVideoFile.getAbsolutePath());
                    androidStepHandler.log.sendRecordLog(false, fileName, "");
                    return;
                }
                
                // 等待文件写入完成（文件大小稳定）
                long lastSize = 0;
                int stableCount = 0;
                for (int i = 0; i < 10; i++) {
                    Thread.sleep(500);
                    long currentSize = localVideoFile.length();
                    if (currentSize == lastSize && currentSize > 0) {
                        stableCount++;
                        if (stableCount >= 2) {
                            break;
                        }
                    } else {
                        stableCount = 0;
                    }
                    lastSize = currentSize;
                }
                
                if (localVideoFile.length() == 0) {
                    log.warn("Video file is empty: {}", localVideoFile.getAbsolutePath());
                    androidStepHandler.log.sendRecordLog(false, fileName, "");
                    return;
                }
                
                log.info("Video file pulled successfully: {} ({} bytes)", fileName, localVideoFile.length());
                
                // 上传视频文件
                String uploadUrl = UploadTools.uploadPatchRecord(localVideoFile);
                androidStepHandler.log.sendRecordLog(true, fileName, uploadUrl);
                log.info("Video file uploaded successfully: {}", fileName);
                
                // 删除设备上的临时文件
                try {
                    AndroidDeviceBridgeTool.executeCommand(finalDevice, "rm -f " + remoteVideoPath);
                } catch (Exception e) {
                    log.warn("Failed to delete remote video file: {}", e.getMessage());
                }
                
            } catch (Exception e) {
                log.error("Failed to process video file: {}", e.getMessage(), e);
                androidStepHandler.log.sendRecordLog(false, fileName, "");
            }
            
        } catch (Exception e) {
            log.error("Recording failed: {}", e.getMessage(), e);
            if (androidStepHandler != null) {
                long timeMillis = Calendar.getInstance().getTimeInMillis();
                String fileName = timeMillis + "_" + udId.substring(0, Math.min(4, udId.length())) + ".mp4";
                androidStepHandler.log.sendRecordLog(false, fileName, "");
            }
        } finally {
            // 清理：确保停止录制和删除临时文件
            if (iDevice != null && remoteVideoPath != null) {
                try {
                    // 再次尝试停止录制（使用 ps 命令）
                    String pidOutput = AndroidDeviceBridgeTool.executeCommand(iDevice, "ps | grep screenrecord | grep -v grep");
                    if (pidOutput == null || pidOutput.trim().isEmpty()) {
                        pidOutput = AndroidDeviceBridgeTool.executeCommand(iDevice, "ps -A | grep screenrecord");
                    }
                    if (pidOutput != null && !pidOutput.trim().isEmpty()) {
                        String[] lines = pidOutput.trim().split("\n");
                        for (String line : lines) {
                            if (line.contains("screenrecord")) {
                                String[] parts = line.trim().split("\\s+");
                                if (parts.length >= 2) {
                                    String pid = parts[1];
                                    try {
                                        AndroidDeviceBridgeTool.executeCommand(iDevice, "kill -9 " + pid);
                                    } catch (Exception e) {
                                        // 忽略错误
                                    }
                                }
                            }
                        }
                    }
                    // 删除设备上的临时文件
                    AndroidDeviceBridgeTool.executeCommand(iDevice, "rm -f " + remoteVideoPath);
                } catch (Exception e) {
                    log.debug("Cleanup error: {}", e.getMessage());
                }
            }
        }
    }
}
