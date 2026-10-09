import { describe, expect, it } from "vitest";
import { reviewToolSchemas } from "../src/review-contracts.js";
const identity = {sessionId:"s",revision:1,documentId:"d",reviewRevision:2,nodeId:0};
describe("additive read-only review contracts",()=>{
 it("bounds paging and input independently of native backend",()=>{
   expect(reviewToolSchemas.get_review.safeParse({...identity,limit:101}).success).toBe(false);
   expect(reviewToolSchemas.get_review.safeParse({...identity,offset:-1}).success).toBe(false);
   expect(reviewToolSchemas.get_review.parse(identity).limit).toBe(50);
   expect(reviewToolSchemas.get_review.safeParse({...identity,pageIdentity:"a".repeat(65)}).success).toBe(false);
   expect(reviewToolSchemas.open_review.safeParse({sessionId:"s",revision:1,source:"current",expectedReviewRevision:2}).success).toBe(true);
   expect(reviewToolSchemas.open_review.safeParse({sessionId:"s",revision:1,source:"paste",text:"x".repeat(65537)}).success).toBe(false);
 });
 it("requires exact document/node/revision scope and validates UCI",()=>{
   expect(reviewToolSchemas.preview_review_line.safeParse({...identity,moves:["e2e4"]}).success).toBe(true);
   expect(reviewToolSchemas.preview_review_line.safeParse({...identity,moves:["e2e9"]}).success).toBe(false);
   expect(reviewToolSchemas.preview_review_line.safeParse({...identity,moves:["e2e4"],path:"/tmp/game"}).success).toBe(false);
   expect(reviewToolSchemas.analyze_review.safeParse({sessionId:"s",revision:1}).success).toBe(false);
 });
});
