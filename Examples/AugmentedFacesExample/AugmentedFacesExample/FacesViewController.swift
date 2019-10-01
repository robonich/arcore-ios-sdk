/*
 * Copyright 2019 Google LLC. All Rights Reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import UIKit
import CoreMedia
import CoreMotion
import SceneKit
import AVFoundation
import ARCore

/// Demonstrates how to use ARCore Augmented Faces with SceneKit.
public final class FacesViewController: UIViewController {

  // MARK: - Camera properties

  private let kCameraZNear = CGFloat(0.05)
  private let kCameraZFar = CGFloat(100)
  private var captureDevice: AVCaptureDevice?
  private var captureSession: AVCaptureSession?
  private lazy var cameraImageLayer = CALayer()
  private let faceVertexIdList = [
      20, 425, 352, 131, 211, 212, 330, 213, 167, 948, 130, 946, 466, 472, 940, 464, 938, 468, 936, 928, 934, 926, 932, 924 ,920, 922, 918, 998, 916, 996, 914, 1048, 994, 912, 910, 908, 907, 906, 822, 1216, 1215, 1214, 1001, 1005, 1000, 807, 966, 888,   942, 579, 616, 661, 765, 660, 659, 580, 783, 853
  ]

  // MARK: - Scene properties

  private let kCentimetersToMeters: Float = 0.01
  private lazy var faceMeshConverter = FaceMeshGeometryConverter()
  private lazy var sceneView = SCNView()
  private lazy var sceneCamera = SCNCamera()
  private lazy var faceNode = SCNNode()
  private lazy var faceTextureNode = SCNNode()
  private lazy var faceOccluderNode = SCNNode()
  private var faceTextureMaterial = SCNMaterial()
  private var faceOccluderMaterial = SCNMaterial()
  private var noseTipNode: SCNNode?
  private var foreheadLeftNode: SCNNode?
  private var foreheadRightNode: SCNNode?

  // MARK: - Motion properties

  private let kMotionUpdateInterval: TimeInterval = 0.1
  private lazy var motionManager = CMMotionManager()

  // MARK: - Face Session properties

  private var faceSession : GARAugmentedFaceSession?
  private var currentFaceFrame: GARAugmentedFaceFrame?
  private var nextFaceFrame: GARAugmentedFaceFrame?

  // MARK: - Implementation methods

  override public func viewDidLoad() {
    super.viewDidLoad()

    setupScene()
    setupCamera()
    setupMotion()

    do {
      let fieldOfView = captureDevice?.activeFormat.videoFieldOfView ?? 0
      faceSession = try GARAugmentedFaceSession(fieldOfView: fieldOfView)
      faceSession?.delegate = self
    } catch let error as NSError {
      NSLog("Failed to initialize Face Session with error: %@", error.description)
    }
  }

  /// Create the scene view from a scene and supporting nodes, and add to the view.
  /// The scene is loaded from 'fox_face.scn' which was created from 'canonical_face_mesh.fbx', the
  /// canonical face mesh asset.
  /// https://developers.google.com/ar/develop/developer-guides/creating-assets-for-augmented-faces
  private func setupScene() {
    guard let faceImage = UIImage(named: "Face.scnassets/koko_face.png"),
      let scene = SCNScene(named: "Face.scnassets/fox_face.scn"),
      let modelRoot = scene.rootNode.childNode(withName: "asset", recursively: false)
    else {
        fatalError("Failed to load face scene!")
    }

    // SceneKit uses meters for units, while the canonical face mesh asset uses centimeters.
    modelRoot.simdScale = simd_float3(1, 1, 1) * kCentimetersToMeters
    foreheadLeftNode = modelRoot.childNode(withName: "FOREHEAD_LEFT", recursively: true)
    foreheadRightNode = modelRoot.childNode(withName: "FOREHEAD_RIGHT", recursively: true)
    noseTipNode = modelRoot.childNode(withName: "NOSE_TIP", recursively: true)

    faceNode.addChildNode(faceTextureNode)
    faceNode.addChildNode(faceOccluderNode)
    scene.rootNode.addChildNode(faceNode)

    let cameraNode = SCNNode()
    cameraNode.camera = sceneCamera
    scene.rootNode.addChildNode(cameraNode)

    sceneView.scene = scene
    sceneView.frame = view.bounds
    sceneView.delegate = self
    sceneView.rendersContinuously = true
    sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    sceneView.backgroundColor = .clear
    view.addSubview(sceneView)

    faceTextureMaterial.diffuse.contents = faceImage
    // SCNMaterial does not premultiply alpha even with blendMode set to alpha, so do it manually.
    faceTextureMaterial.shaderModifiers =
        [SCNShaderModifierEntryPoint.fragment : "_output.color.rgb *= _output.color.a;"]
    faceOccluderMaterial.colorBufferWriteMask = []
  }

  /// Setup a camera capture session from the front camera to receive captures.
  private func setupCamera() {
    guard let device =
      AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
      let input = try? AVCaptureDeviceInput(device: device)
    else {
      fatalError("Failed to create capture device from front camera.")
    }

    let output = AVCaptureVideoDataOutput()
    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    output.setSampleBufferDelegate(self, queue: DispatchQueue.global(qos: .userInteractive))

    let session = AVCaptureSession()
    session.sessionPreset = .high
    session.addInput(input)
    session.addOutput(output)
    captureSession = session
    captureDevice = device

    cameraImageLayer.contentsGravity = .center
    cameraImageLayer.frame = sceneView.bounds
    view.layer.insertSublayer(cameraImageLayer, at: 0)

    startCameraCapture()
  }

  /// Start receiving motion updates to determine device orientation for use in the face session.
  private func setupMotion() {
    guard motionManager.isDeviceMotionAvailable else {
      fatalError("Device does not have motion sensors.")
    }
    motionManager.deviceMotionUpdateInterval = kMotionUpdateInterval
    motionManager.startDeviceMotionUpdates()
  }

  /// Start capturing images from the capture session once permission is granted.
  private func startCameraCapture() {
    getVideoPermission(permissionHandler: { granted in
      guard granted else {
        fatalError("Permission not granted to use camera.")
      }
      self.captureSession?.startRunning()
    })
  }

  /// Get permission to use device camera.
  ///
  /// - Parameters:
  ///   - permissionHandler: The closure to call with whether permission was granted when
  ///     permission is determined.
  private func getVideoPermission(permissionHandler: @escaping (Bool) -> ()) {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      permissionHandler(true)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video, completionHandler: permissionHandler)
    default:
      permissionHandler(false)
    }
  }

  /// Update a region node's transform with the transform from the face session. Ignore the scale
  /// on the passed in transform to preserve the root level unit conversion.
  ///
  /// - Parameters:
  ///   - transform: The world transform to apply to the node.
  ///   - regionNode: The region node on which to apply the transform.
  private func updateTransform(_ transform: simd_float4x4, for regionNode: SCNNode?) {
    guard let node = regionNode else { return }

    let localScale = node.simdScale
    node.simdWorldTransform = transform
    node.simdScale = localScale

    // The .scn asset (and the canonical face mesh asset that it is created from) have their
    // 'forward' (Z+) opposite of SceneKit's forward (Z-), so rotate to orient correctly.
    node.simdLocalRotate(by: simd_quatf(angle: .pi, axis: simd_float3(0, 1, 0)))
  }

}

// MARK: - Camera delegate

extension FacesViewController : AVCaptureVideoDataOutputSampleBufferDelegate {

  public func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
    ) {
    guard let imgBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
      let deviceMotion = motionManager.deviceMotion
    else { return }

    let frameTime = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))

    // Use the device's gravity vector to determine which direction is up for a face. This is the
    // positive counter-clockwise rotation of the device relative to landscape left orientation.
    let rotation =  2 * .pi + atan2(deviceMotion.gravity.x, deviceMotion.gravity.y) + .pi / 2
    let rotationDegrees = (UInt)(rotation * 180 / .pi) % 360

    faceSession?.update(
      with: imgBuffer,
      timestamp: frameTime,
      recognitionRotation: rotationDegrees)
  }

}

// MARK: - Face Session delegate

extension FacesViewController : GARAugmentedFaceSessionDelegate {

  public func didUpdate(_ frame: GARAugmentedFaceFrame) {
    // To present the AR content mirrored (as is normal with a front facing camera), pass 'true' to
    // the 'mirrored' param, which flips the projection matrix along the long axis of the
    // 'presentationOrientation'. This requires the winding order to be changed from
    // counter-clockwise to clockwise in order to render correctly. However, due to an issue in
    // SceneKit on iOS >= 12 which causes the renderer to not respect the winding order set, we set
    // 'mirrored' to 'false' and instead flip the sceneView along the same axis.
    // https://openradar.appspot.com/6699866
    sceneCamera.projectionTransform = SCNMatrix4.init(
      frame.projectionMatrix(
        forViewportSize: sceneView.bounds.size,
        presentationOrientation: .portrait,
        mirrored: false,
        zNear: kCameraZNear,
        zFar: kCameraZFar)
    )
//    sceneView.layer.transform = CATransform3DMakeScale(-1, 1, 1)

    nextFaceFrame = frame
  }

}

// MARK: - Scene Renderer delegate

extension FacesViewController : SCNSceneRendererDelegate {

  public func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
    guard nextFaceFrame != nil && nextFaceFrame != currentFaceFrame else { return }

    currentFaceFrame = nextFaceFrame

    if let face = currentFaceFrame?.face {
      faceTextureNode.geometry = faceMeshConverter.geometryFromFace(face)
      faceTextureNode.geometry?.firstMaterial = faceTextureMaterial
      faceOccluderNode.geometry = faceTextureNode.geometry?.copy() as? SCNGeometry
      faceOccluderNode.geometry?.firstMaterial = faceOccluderMaterial
        
      let faceOutlines = faceVertexIdList.map { face.mesh.vertices[$0] }
      let modelMatrix = faceTextureNode.transform
      
      let size = sceneView.currentViewport
      guard let camera = sceneView.session.currentFrame.camera else { return }
      sceneView.trans
      
      let textureCoordinates = faceOutlines.map { vertex -> CGPoint in
        let vertex4 = vector_float4(vertex.x, vertex.y, vertex.z, 1)
        let world_vertex4 = simd_mul(modelMatrix, vertex4)
        let world_vector3 = simd_float3(x: world_vertex4.x / world_vertex4.w, y: world_vertex4.y / world_vertex4.w, z: world_vertex4.z / world_vertex4.w)
        let pt = camera.projectPoint(world_vector3,
                      orientation: .portrait,
                      viewportSize: sceneView.currentViewport)
        camera.projectPo
                  let v = 1.0 - Float(pt.x) / Float(size.height)
                  let u = Float(pt.y) / Float(size.width)

      //            let vectorFloat = vector_float2(u, v)

                  return CGPoint(x: CGFloat(u) * self.sceneView.bounds.width, y: CGFloat(v) * self.sceneView.bounds.height)

              }

      faceNode.simdWorldTransform = face.centerTransform
      updateTransform(face.transform(for: .nose), for: noseTipNode)
      updateTransform(face.transform(for: .foreheadLeft), for: foreheadLeftNode)
      updateTransform(face.transform(for: .foreheadRight), for: foreheadRightNode)
    }

    // Only show AR content when a face is detected
    sceneView.scene?.rootNode.isHidden = currentFaceFrame?.face == nil
  }

  public func renderer(
    _ renderer: SCNSceneRenderer,
    didRenderScene scene: SCNScene,
    atTime time: TimeInterval
    ) {
    guard let frame = currentFaceFrame else { return }

    CATransaction.begin()
    CATransaction.setAnimationDuration(0)
    cameraImageLayer.contents = frame.capturedImage as CVPixelBuffer
    cameraImageLayer.setAffineTransform(
      frame.displayTransform(
        forViewportSize: cameraImageLayer.bounds.size,
        presentationOrientation: .portrait,
        mirrored: false)
    )
    CATransaction.commit()
  }

}
