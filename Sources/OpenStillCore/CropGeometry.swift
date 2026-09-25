import Foundation

/// Crop rectangles use normalized coordinates; aspect ratios use actual image pixels.
public enum CropGeometry {
    public static func centered(in size: CGSize, aspect: Double) -> CGRect {
        guard size.width > 0, size.height > 0, aspect.isFinite, aspect > 0 else { return CGRect(x:0,y:0,width:1,height:1) }
        let ratio = aspect * size.height / size.width
        let width = min(1,ratio), height = min(1,1/ratio)
        return CGRect(x:(1-width)/2,y:(1-height)/2,width:width,height:height)
    }
    public static func rectangle(from start: CGPoint, to end: CGPoint, in size: CGSize, aspect: Double?) -> CGRect {
        let end = CGPoint(x:min(1,max(0,end.x)),y:min(1,max(0,end.y)))
        let sx = end.x < start.x ? -1.0 : 1.0, sy = end.y < start.y ? -1.0 : 1.0
        var width = abs(end.x-start.x), height = abs(end.y-start.y)
        if let aspect, aspect.isFinite, aspect > 0, size.width > 0, size.height > 0 {
            let ratio = aspect * size.height / size.width
            width = max(width,height*ratio)
            let availableWidth = sx > 0 ? 1-start.x : start.x
            let availableHeight = sy > 0 ? 1-start.y : start.y
            width = min(width,availableWidth,availableHeight*ratio); height = width/ratio
        }
        return CGRect(x:sx > 0 ? start.x:start.x-width,y:sy > 0 ? start.y:start.y-height,width:width,height:height)
    }
    public static func moving(_ rect: CGRect, by delta: CGPoint) -> CGRect {
        CGRect(x:min(1-rect.width,max(0,rect.minX+delta.x)),y:min(1-rect.height,max(0,rect.minY+delta.y)),width:rect.width,height:rect.height)
    }
}
