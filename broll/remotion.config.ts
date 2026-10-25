import { Config } from "@remotion/cli/config";

Config.setVideoImageFormat("png");
Config.setPixelFormat("yuv420p");
Config.setCodec("h264");
Config.setCrf(16);
Config.setAudioCodec("aac");
Config.setAudioBitrate("320k");
Config.setConcurrency(12);
Config.setChromiumOpenGlRenderer("angle");
