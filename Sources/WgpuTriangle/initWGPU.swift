import Foundation
import SDL2
import SwiftWgpuTools

func initWGPU(window: OpaquePointer) -> (surface: WGPUSurface, device: WGPUDevice, queue: WGPUQueue, config: WGPUSurfaceConfiguration) {

    // Get window size & scaleFactor
    var drawableSize = (width: Int32(0), height: Int32(0))
    SDL_GL_GetDrawableSize(window, &drawableSize.width, &drawableSize.height)
    drawableSize.width = max(drawableSize.width, 1)
    drawableSize.height = max(drawableSize.height, 1)

    var logicalSize = (width: Int32(0), height: Int32(0))
    SDL_GetWindowSize(window, &logicalSize.width, &logicalSize.height)
    logicalSize.width = max(logicalSize.width, 1)
    logicalSize.height = max(logicalSize.height, 1)

    let scaleFactor = Double(drawableSize.width) / Double(logicalSize.width)

    // Crear WGPU instance
    var extras = WGPUInstanceExtras(
        chain: WGPUChainedStruct(next: nil, sType: BACKEND_CHAIN),
        backends: WGPUInstanceBackendFlags(BACKEND_FLAGS),
        flags: 0,
        dx12ShaderCompiler: WGPUDx12Compiler_Dxc,
        gles3MinorVersion: WGPUGles3MinorVersion_Automatic,
        dxilPath: nil,
        dxcPath: nil
    )

    var descriptor = withUnsafePointer(to: &extras.chain) { chainPointer in WGPUInstanceDescriptor(nextInChain: chainPointer) }
    guard let instance = withUnsafePointer(to: &descriptor, { wgpuCreateInstance($0) }) else {
        fatalError("Could not initialize WGPU instance")
    }
    
    // List adapters
    print("Available adapters:")
    
    let backendFlags: WGPUInstanceBackendFlags = WGPUInstanceBackendFlags(BACKEND_FLAGS)
    var enumerateOptions = WGPUInstanceEnumerateAdapterOptions(nextInChain: nil, backends: backendFlags)
    let adapterCount = wgpuInstanceEnumerateAdapters(instance, &enumerateOptions, nil)
    var adapters: [WGPUAdapter?] = Array(repeating: nil, count: Int(adapterCount))
    let bufferPointer = adapters.withUnsafeMutableBufferPointer { $0 }
    wgpuInstanceEnumerateAdapters(instance, &enumerateOptions, bufferPointer.baseAddress)

    for adapter in adapters {
        if let adapter = adapter {
            var properties = WGPUAdapterProperties()
            wgpuAdapterGetProperties(adapter, &properties)
            print("   \(String(cString: properties.name))")
        }
    }

    // Get a surface
    guard let surface = getWGPUSurface(instance: instance, window: window) else {
        fatalError("Failed to create WGPU surface")
    }

    // Get an adapter
    var adapter: WGPUAdapter? = nil
    var options = WGPURequestAdapterOptions(
        nextInChain: nil,
        compatibleSurface: surface,
        powerPreference: WGPUPowerPreference_HighPerformance,
        backendType: WGPUBackendType_Undefined,
        forceFallbackAdapter: WGPUBool(0)
    )
    
    
    // Crear un contenidor per a passar l'adapter i el semàfor
    let adapterRequestData = RequestData(pointer: &adapter)   
    wgpuInstanceRequestAdapter(instance, &options, requestAdapterCallback, adapterRequestData.getRawPointer())
    
    print("Waiting Adapter Semaphore")
    adapterRequestData.wait()

    guard let adapter = adapter else {
        fatalError("Failed to get WGPU adapter")
    }

    // Request a device and queue from the adapter
    var deviceDescriptor = WGPUDeviceDescriptor(
        nextInChain: nil, 
        label: nil, 
        requiredFeatureCount: 0, 
        requiredFeatures: nil, 
        requiredLimits: nil,     
        defaultQueue: WGPUQueueDescriptor(nextInChain: nil, label: nil),
        deviceLostCallback: nil, 
        deviceLostUserdata: nil  
    )

    var device: WGPUDevice? = nil
    
    let deviceRequestData = RequestData(pointer: &device)   
    wgpuAdapterRequestDevice(adapter, &deviceDescriptor, requestDeviceCallback, deviceRequestData.getRawPointer())

    print("Waiting Device Semaphore")
    deviceRequestData.wait()

    
    // Get the device and queue
    guard let device = device else {
        fatalError("Failed to create WGPU device")
    }
    guard let queue = wgpuDeviceGetQueue(device) else {
        fatalError("Failed to get WGPU queue")
    }

    // Configure the surface
    var surfaceConfig = WGPUSurfaceConfiguration(
        nextInChain: nil,
        device: device,
        format: WGPUTextureFormat_BGRA8Unorm, // The format used in the original code
        usage: WGPUTextureUsage_RenderAttachment.rawValue,
        viewFormatCount: 0, // Set to 0 if you're not using additional view formats
        viewFormats: nil,   // Set to nil if no additional view formats are used
        alphaMode: WGPUCompositeAlphaMode_Auto, // Default alpha mode
        width: UInt32(Double(logicalSize.width) * scaleFactor),
        height: UInt32(Double(logicalSize.height) * scaleFactor),
        presentMode: WGPUPresentMode_Fifo // The present mode used in the original code
    )
    wgpuSurfaceConfigure(surface, &surfaceConfig)
    
    return (surface, device, queue, surfaceConfig)
}

func requestAdapterCallback(status: WGPURequestAdapterStatus, requestedAdapter: WGPUAdapter?, message: UnsafePointer<CChar>?, userData: UnsafeMutableRawPointer?) {
    print("Adapter callback executed with status: \(status.rawValue)")
    
    if let userData = userData {
        let requestData = Unmanaged<RequestData<WGPUAdapter>>.fromOpaque(userData).takeUnretainedValue()

        if status == WGPURequestAdapterStatus_Success, let adapter = requestedAdapter {
            requestData.pointer.pointee = adapter
            var properties = WGPUAdapterProperties()
            wgpuAdapterGetProperties(adapter, &properties)
            print("Selected adapter:")
            print("   Adapter Name: \(String(cString: properties.name))")
            print("   Vendor ID: \(properties.vendorID)")
            print("   Device ID: \(properties.deviceID)")
            print("   Backend Type: \(properties.backendType.rawValue)")
        } else {
            let errorMessage = message != nil ? String(cString: message!) : "Unknown error"
            print("Adapter request failed: \(errorMessage)")
        }

        print("Adapter Semaphore signal")
        requestData.resumeSignal()
    } else {
        print("Error: userData is nil")
    }
}

func requestDeviceCallback(status: WGPURequestDeviceStatus, requestedDevice: WGPUDevice?, message: UnsafePointer<CChar>?, userData: UnsafeMutableRawPointer?) {
    print("Device callback executed with status: \(status.rawValue)")

    if let userData = userData {
        let requestData = Unmanaged<RequestData<WGPUDevice>>.fromOpaque(userData).takeUnretainedValue()

        if status == WGPURequestDeviceStatus_Success, let device = requestedDevice {
            requestData.pointer.pointee = device
            print("WGPU device successfully created.")
        } else {
            let errorMessage = message != nil ? String(cString: message!) : "Unknown error"
            print("Device request failed: \(errorMessage)")
        }

        print("Device Semaphore signal")
        requestData.resumeSignal()
    } else {
        print("Error: userData is nil")
    }
}
